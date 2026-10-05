#if DEBUG
import SwiftUI
import AVFoundation
import os

/// URLProtocol is a deterministic controlled ABS server, not a mock of the outbox:
/// tests exercise the real Abs HTTP/auth, disk, merge and replay integration.
struct ProgressFixture: View {
    @State private var result = "Running"
    var body: some View {
        Text(result).accessibilityIdentifier("progress-result")
            .task {
                do {
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("--progress-seed") { try await ProgressChecks.relaunch(seed: true); result = "PASS seeded" }
                    else if args.contains("--progress-drain") { try await ProgressChecks.relaunch(seed: false); result = "PASS relaunched" }
                    else if args.contains("--progress-playback-auth") { try await ProgressChecks.playbackAuthenticationRegressions(); result = "PASS playback authentication" }
                    else { try await ProgressChecks.run(); result = "PASS progress replay" }
                }
                catch { result = "FAIL \(error.localizedDescription)" }
                print(result)
            }
    }
}

final class ProgressServer: URLProtocol, @unchecked Sendable {
    struct State {
        var offline = false
        var reject = false
        var failRefresh = false
        var failPatch = false
        var refreshes = 0
        var patches = 0
        var requests = 0
        var rows: [String: [String: Any]] = [:]
        var holdLogin = false
        var holdRefresh = false
        var holdGet: String?
        var holdPatch = false
        var holdLinkedRead = false
        var held: ProgressServer?
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { ["abs-progress-fixture.invalid", "abs-progress-other.invalid"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let held = Self.state.withLock { s in
            if s.holdGet == request.url?.path && request.httpMethod == "GET" { s.held = self; s.holdGet = nil; return true }
            if s.holdRefresh && request.url?.path == "/auth/refresh" { s.held = self; s.holdRefresh = false; return true }
            if s.holdLogin && request.url?.path == "/login" { s.held = self; s.holdLogin = false; return true }
            if s.holdLinkedRead && request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer linked" { s.held = self; s.holdLinkedRead = false; return true }
            if s.holdPatch && request.httpMethod == "PATCH" { s.held = self; s.holdPatch = false; return true }
            return false
        }
        if !held { respond() }
    }
    func respond() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(bytes, count: n) }
            body = data
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let response: (Int, [String: Any]) = Self.state.withLock { s in
            s.requests += 1
            if s.offline { return (-1, [:]) }
            let path = request.url!.path
            if path == "/ping" || path == "/logout" { return (200, [:]) }
            if path == "/auth/refresh" {
                s.refreshes += 1
                if s.failRefresh { return (401, [:]) }
                let name = request.value(forHTTPHeaderField: "x-refresh-token") ?? "own"
                s.reject = false
                return (200, ["user": ["username": name, "accessToken": name + "-refreshed", "refreshToken": name]])
            }
            if s.reject { return (401, [:]) }
            if path == "/login" {
                let name = json["username"] as? String ?? "own"
                return (200, ["user": ["username": name, "id": name, "accessToken": name, "refreshToken": name]])
            }
            let name = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "").replacingOccurrences(of: "-refreshed", with: "") ?? ""
            let key = name + ":" + path.replacingOccurrences(of: "/api/me/progress/", with: "")
            if request.httpMethod == "PATCH" {
                if s.failPatch { return (503, [:]) }
                s.patches += 1
                let row = Self.apply(json, to: s.rows[key])
                var identified = row
                let parts = path.replacingOccurrences(of: "/api/me/progress/", with: "").split(separator: "/")
                identified["libraryItemId"] = String(parts[0])
                if parts.count > 1 { identified["episodeId"] = String(parts[1]) }
                s.rows[key] = identified
                return (200, [:])
            }
            return s.rows[key].map { (200, $0) } ?? (404, [:])
        }
        if response.0 == -1 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response.1))
        client?.urlProtocolDidFinishLoading(self)
    }
    /// Mirrors User.createUpdateMediaProgressFromPayload and MediaProgress.applyProgressUpdate:
    /// wire progress is extraData.progress, not the computed currentTime/duration getter.
    static func apply(_ payload: [String: Any], to existing: [String: Any]?) -> [String: Any] {
        guard var row = existing else {
            var row = payload
            row["isFinished"] = payload["isFinished"] as? Bool ?? false
            row["progress"] = (row["isFinished"] as? Bool == true) ? 1.0 : payload["progress"] ?? 0.0
            row["lastUpdate"] = ms() + 1000 // first creation ignores client lastUpdate
            return row
        }
        var update = payload
        let oldTime = row["currentTime"] as? Double ?? 0
        let wasFinished = row["isFinished"] as? Bool ?? false
        let oldDuration = row["duration"] as? Double ?? 0
        let fraction = oldDuration > 0 ? min(1, max(0, oldTime / oldDuration)) : 0
        if let finished = update["isFinished"] as? Bool {
            if finished && !wasFinished { row["progress"] = 1.0 }
            else if !finished && wasFinished {
                row["progress"] = 0.0
                row["currentTime"] = 0.0
                update["currentTime"] = nil // ABS explicitly discards the supplied position
            }
        } else if let progress = update["progress"] as? Double, progress != fraction {
            row["progress"] = min(1, max(0, progress))
        }
        update["progress"] = nil // not a model column; only the branch above updates extraData
        row.merge(update) { _, new in new }
        let time = row["currentTime"] as? Double ?? 0
        let duration = row["duration"] as? Double ?? 0
        let threshold = payload["markAsFinishedPercentComplete"] as? Double ?? 0
        let done = duration > 0 && (threshold > 0
            ? min(1, max(0, time / duration)) > threshold / 100
            : duration - time < (payload["markAsFinishedTimeRemaining"] as? Double ?? 10))
        if row["isFinished"] as? Bool != true && done {
            row["isFinished"] = true
            row["progress"] = 1.0
        } else if row["isFinished"] as? Bool == true && time != oldTime && !done {
            row["isFinished"] = false
        }
        return row
    }
    override func stopLoading() {}
}

@MainActor enum ProgressChecks {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        if !ok() { throw Msg(errorDescription: message) }
    }
    static func wait(_ label: String = "condition", file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        print("Progress fixture: waiting for \(label) at \(file):\(line)")
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Msg(errorDescription: "Timed out waiting for \(label) at \(file):\(line)")
    }
    static func configured(defaults: UserDefaults, progressFile: URL, accounts: [String: Tok]) -> Abs {
        let a = Abs(defaults: defaults, progressFile: progressFile, accounts: accounts)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProgressServer.self]
        a.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
        return a
    }

    static func authenticated(_ d: UserDefaults, _ file: URL, _ requested: [String: Tok]) async throws -> Abs {
        let endpoint = d.string(forKey: "server") ?? "http://abs-progress-fixture.invalid"
        let owner = d.string(forKey: "me") ?? "own"
        if requested.values.allSatisfy({ $0.host != nil }) {
            return configured(defaults: d, progressFile: file, accounts: requested)
        }
        if let data = d.data(forKey: "fixtureAccounts"), let saved = try? JSONDecoder().decode([String: Tok].self, from: data) {
            return configured(defaults: d, progressFile: file, accounts: saved)
        }
        let state = ProgressServer.state.withLock { s in let old = s; s = .init(); return old }
        defer { ProgressServer.state.withLock { $0 = state } }
        let a = configured(defaults: d, progressFile: file, accounts: [:])
        _ = try await a.login(endpoint, owner, "fixture", main: true)
        for name in requested.keys.sorted() where name != owner { _ = try await a.login(endpoint, name, "fixture", main: false) }
        d.set(try JSONEncoder().encode(a.accts), forKey: "fixtureAccounts")
        return a
    }

    static func stop(_ a: Abs) async {
        a.progressTask?.cancel()
        await a.progressTask?.value
    }
    static func due(_ a: Abs) {
        for i in a.progressDisk.pending.indices { a.progressDisk.pending[i].retryAt = 0 }
        a.persistProgress()
    }
    static func relaunch(seed: Bool) async throws {
        URLProtocol.registerClass(ProgressServer.self)
        ProgressServer.state.withLock { $0 = .init(); $0.offline = seed }
        let d = UserDefaults(suiteName: "progress-relaunch-fixture")!
        let file = URL.applicationSupportDirectory.appending(path: "progress-relaunch-fixture.json")
        if seed {
            d.removePersistentDomain(forName: "progress-relaunch-fixture")
            try? FileManager.default.removeItem(at: file)
            d.set("http://abs-progress-fixture.invalid", forKey: "server")
            d.set("own", forKey: "me")
        }
        let a = try await authenticated(d, file, ["own": Tok(a: "own", r: "own")])
        if seed {
            let n = Now(item: "restart", ep: "episode", title: "Fixture", author: "", tracks: [Track(ino: "0", ext: ".wav", size: 0, duration: 100, start: 0)])
            a.push(n, 100, finished: true)
            await stop(a)
            due(a)
        } else {
            try check(a.pct("restart/episode") == 1 && a.progressDisk.pending.count == 1, "process relaunch lost queue")
            a.startProgressReplay()
            try await wait { a.progressDisk.pending.isEmpty }
            try check(ProgressServer.state.withLock { $0.rows["own:restart/episode"]?["isFinished"] as? Bool } == true, "process relaunch did not upload without playback")
            d.removePersistentDomain(forName: "progress-relaunch-fixture")
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Authentication can fail before AVFoundation has an item to report an error.
    static func playbackAuthenticationRegressions() async throws {
        URLProtocol.registerClass(ProgressServer.self)
        ProgressServer.state.withLock { $0 = .init() }
        let suite = "playback-auth-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let origin = "http://abs-progress-fixture.invalid"
        d.set(origin, forKey: "server"); d.set("own", forKey: "me")
        let a = try await authenticated(d, file, ["own": Tok(a: "own", r: "own")])
        let p = Player(source: a)
        p.p.defaultRate = 1
        defer { p.clear(); a.progressTask?.cancel() }
        let track = Track(ino: "silent", ext: ".wav", size: 0, duration: 40, start: 0)
        let remote = Now(item: suite + "-remote", ep: nil, title: "Remote fixture", author: "", tracks: [track])
        var local = Now(item: suite + "-local", ep: nil, title: "Local fixture", author: "", tracks: [track])
        let wav = a.file(local.item, track)
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        do {
            let audio = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320000)!
            buffer.frameLength = 320000
            try audio.write(from: buffer)
        }
        local = Now(item: local.item, ep: nil, title: local.title, author: "",
                    tracks: [Track(ino: track.ino, ext: track.ext, size: a.size(wav), duration: 40, start: 0)])
        // An expired synthetic JWT forces the production refresh path.
        let expired = "fixture.eyJleHAiOjB9.signature"
        a.accts["own"]!.a = expired
        ProgressServer.state.withLock { $0.failRefresh = true }
        p.start(remote, 0)
        try await wait("stream authentication terminal feedback") { p.playbackError != nil }
        try check(!p.buffering && !p.playing && p.p.currentItem == nil && p.now == remote && a.toast == p.playbackError,
                  "failed refresh left remote playback buffering or without retry feedback")
        let refreshes = ProgressServer.state.withLock { $0.refreshes }
        p.play() // same path as the production Retry playback control
        try await wait("explicit playback retry fails terminally") { p.playbackError != nil }
        try check(!p.buffering && ProgressServer.state.withLock { $0.refreshes } > refreshes,
                  "authentication error did not permit an explicit retry")

        ProgressServer.state.withLock { $0.offline = true }
        p.start(local, 0)
        try await wait("offline local playback despite refresh failure") { p.pos > 0.3 && p.playing && !p.buffering }
        try check(p.playbackError == nil && (p.p.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true,
                  "authentication failure prevented downloaded playback")
        p.clear()
        await stop(a)

        // Hold the old queue's refresh, then commit a newer queue with fresh auth.
        // Its late failure must neither publish a toast nor clear new playback.
        ProgressServer.state.withLock { $0.offline = false; $0.holdRefresh = true }
        p.start(remote, 0)
        try await wait("stale queue refresh held") { ProgressServer.state.withLock { $0.held != nil } }
        let held = ProgressServer.state.withLock { state in let value = state.held; state.held = nil; return value }!
        let settling = Task { try? await a.token(force: true) }
        await Task.yield()
        a.accts["own"]!.a = "own"
        p.start(local, 0)
        try await wait("new queue playing before stale failure") { p.pos > 0.3 && p.playing && !p.buffering }
        a.toast = "new queue feedback"
        held.respond()
        _ = await settling.value
        try await Task.sleep(for: .milliseconds(100))
        try check(p.now == local && p.playing && !p.buffering && p.playbackError == nil && a.toast == "new queue feedback",
                  "stale queue authentication failure changed newer playback or feedback")
        p.clear()
        await stop(a)
    }

    static func reviewRegressions(_ book: Now) async throws {
        let suite = "progress-review-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let origin = "http://abs-progress-fixture.invalid", other = "http://abs-progress-other.invalid"
        d.set(origin, forKey: "server"); d.set("own", forKey: "me")
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        var a = try await authenticated(d, file, accounts)
        defer { a.progressTask?.cancel() }
        ProgressServer.state.withLock { $0.offline = true }
        a.push(book, 20, finished: false)
        await stop(a)
        let generation = a.accountGeneration
        ProgressServer.state.withLock { $0.offline = false; $0.reject = true }
        do { _ = try await a.login(other, "own", "fixture", main: true); throw Msg(errorDescription: "rejected login succeeded") }
        catch let e as Msg { try check(e.errorDescription == "Wrong username or password", "unexpected login result") }
        a.pruneProgress()
        try check(a.server == origin && a.accountGeneration == generation && a.progressDisk.pending.count == 1, "failed login changed scope or erased journal")
        a = try await authenticated(d, file, accounts)
        try check(a.progressDisk.local[book.key]?.currentTime == 20 && a.progressDisk.pending.count == 1, "failed login erased journal on relaunch")

        // Pending/backoff is not evidence of recency: fresh reads must beat T1.
        for i in a.progressDisk.pending.indices { a.progressDisk.pending[i].retryAt = ms() + 300000 }
        let remoteAt = a.progressDisk.local[book.key]!.lastUpdate! + 1000
        ProgressServer.state.withLock { s in
            s.reject = false
            s.rows["own:book"] = ["libraryItemId": "book", "currentTime": 80.0, "isFinished": false, "lastUpdate": remoteAt]
        }
        let positions = await a.positions(book)
        try check(positions.first?.time == 80 && a.progressDisk.pending.isEmpty, "fresh position ignored newer remote during backoff")
        ProgressServer.state.withLock { $0.offline = true }
        a.push(book, 81, finished: false)
        await stop(a)
        try check(a.progressDisk.local[book.key]!.lastUpdate! > remoteAt, "next event did not follow merged remote clock")
        let newer = Prog(libraryItemId: "book", episodeId: nil, progress: 0.9, currentTime: 90, isFinished: false, lastUpdate: remoteAt + 2000)
        a.setMe(Me(mediaProgress: [newer], bookmarks: []))
        try check(a.progressDisk.local[book.key]?.currentTime == 90 && a.progressDisk.pending.isEmpty, "/me ignored newer remote during backoff")
        a = try await authenticated(d, file, accounts)
        try check(a.progressDisk.local[book.key]?.currentTime == 90, "remote merge was not durable")

        // Hold an old-scope replay read across a same-name successful server switch.
        a.shares[book.item] = ["linked"]
        ProgressServer.state.withLock { $0.offline = false; $0.holdLinkedRead = true }
        a.push(book, 91, finished: false)
        try await wait { ProgressServer.state.withLock { $0.held != nil } }
        let oldRead = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
        let oldGeneration = a.accountGeneration
        _ = try await a.login(other, "own", "fixture", main: true)
        let writes = ProgressServer.state.withLock { $0.patches }
        oldRead!.respond()
        await stop(a)
        try check(a.server == other && a.accountGeneration != oldGeneration && a.progressDisk.pending.isEmpty && a.accounts.isEmpty, "successful server switch retained old scope")
        try check(ProgressServer.state.withLock { $0.patches } == writes, "old in-flight read wrote after scope switch")

        // A slower successful login must not replace a later authenticated scope.
        ProgressServer.state.withLock { $0.holdLogin = true }
        let target = a
        let stale = Task { try await target.login(origin, "stale", "fixture", main: true) }
        try await wait { ProgressServer.state.withLock { $0.held != nil } }
        let oldLogin = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
        _ = try await a.login(other, "own", "fixture", main: true)
        oldLogin!.respond()
        do { _ = try await stale.value; throw Msg(errorDescription: "stale login committed") }
        catch is CancellationError {}
        try check(a.server == other && a.me == "own" && a.accts["stale"] == nil, "late login replaced authenticated scope")
        ProgressServer.state.withLock { $0.rows["own:book"] = nil }
    }

    static func passiveCompletionRegressions(_ book: Now) async throws {
        let suite = "progress-passive-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("http://abs-progress-fixture.invalid", forKey: "server"); d.set("own", forKey: "me")
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        var a = try await authenticated(d, file, accounts)
        defer { a.progressTask?.cancel() }
        let titles = [Now(item: "passive-book", ep: nil, title: "Book", author: "", tracks: book.tracks),
                      Now(item: "passive-pod", ep: "episode", title: "Episode", author: "", tracks: book.tracks)]
        let finished: [String: Any] = ["currentTime": 100.0, "duration": 100.0, "progress": 1.0, "isFinished": true, "lastUpdate": 1.0]
        let reset = ProgressServer.apply(["currentTime": 0.0, "duration": 100.0, "progress": 0.0, "isFinished": true], to: finished)
        try check(reset["isFinished"] as? Bool == false, "fixture must normalize completion after a zero-position update")
        ProgressServer.state.withLock { s in
            s.offline = true
            for title in titles { for account in accounts.keys {
                var row = finished
                row["libraryItemId"] = title.item
                row["episodeId"] = title.ep
                s.rows[account + ":" + title.key] = row
            } }
        }
        for title in titles {
            a.shares[title.item] = ["linked"]
            a.push(title, 100, finished: true)
            // Late pause, restore or title-switch callbacks can report zero.
            a.push(title, 0, finished: false)
        }
        await stop(a)
        a = try await authenticated(d, file, accounts)
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        await a.replayProgress()
        try check(a.progressDisk.pending.isEmpty, "passive completion queue did not drain")
        for title in titles { for account in accounts.keys {
            let row = ProgressServer.state.withLock { $0.rows[account + ":" + title.key]! }
            try check(row["currentTime"] as? Double == 100 && row["progress"] as? Double == 1 && row["isFinished"] as? Bool == true,
                      "passive zero cleared remote completion: " + account + ":" + title.key)
        } }
        a = try await authenticated(d, file, accounts)
        // Completion already acknowledged and restored from disk needs the same guard.
        ProgressServer.state.withLock { $0.offline = true }
        for title in titles {
            try check(a.progressDisk.local[title.key]?.currentTime == 100 && a.pct(title.key) == 1, "passive completion readback was not durable")
            a.push(title, 0, finished: false)
        }
        await stop(a)
        a = try await authenticated(d, file, accounts)
        for title in titles {
            try check(a.progressDisk.local[title.key]?.currentTime == 100 && a.pct(title.key) == 1, "passive zero replaced restored completed position")
        }
        try check(a.progressDisk.pending.count == 4 && a.progressDisk.pending.allSatisfy { $0.time == 100 && $0.finished }, "passive completed outbox lost recipient position")
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        await a.replayProgress()
        try check(a.progressDisk.pending.isEmpty, "restored passive completion queue did not drain")
        for title in titles { for account in accounts.keys {
            let row = ProgressServer.state.withLock { $0.rows[account + ":" + title.key]! }
            try check(row["currentTime"] as? Double == 100 && row["isFinished"] as? Bool == true,
                      "restored passive zero cleared remote completion: " + account + ":" + title.key)
        } }
    }

    static func rereadRegressions(_ book: Now) async throws {
        let suite = "progress-reread-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("http://abs-progress-fixture.invalid", forKey: "server"); d.set("own", forKey: "me")
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        var a = try await authenticated(d, file, accounts)
        defer { a.progressTask?.cancel() }
        let titles = [Now(item: "reread-book", ep: nil, title: "Book", author: "", tracks: book.tracks),
                      Now(item: "reread-pod", ep: "episode", title: "Episode", author: "", tracks: book.tracks)]
        let finished: [String: Any] = ["currentTime": 100.0, "duration": 100.0, "progress": 1.0, "isFinished": true, "lastUpdate": 1.0]
        let unread = ProgressServer.apply(["currentTime": 24.0, "progress": 0.24, "isFinished": false], to: finished)
        try check(unread["currentTime"] as? Double == 0 && unread["progress"] as? Double == 0, "fixture must discard time on explicit mark-unread")
        let suppressed = ProgressServer.apply(["currentTime": 25.0, "progress": 0.25, "isFinished": false], to: unread)
        try check(suppressed["progress"] as? Double == 0, "fixture must suppress extraData progress with explicit isFinished")
        ProgressServer.state.withLock { s in
            s.offline = true
            for title in titles { for account in accounts.keys {
                var row = finished
                row["libraryItemId"] = title.item
                row["episodeId"] = title.ep
                s.rows[account + ":" + title.key] = row
            } }
        }
        for title in titles {
            a.shares[title.item] = ["linked"]
            a.progressDisk.local[title.key] = Prog(libraryItemId: title.item, episodeId: title.ep, progress: 1, currentTime: 100, isFinished: true, lastUpdate: 1)
            a.push(title, 0, finished: false, restarting: true)
            a.push(title, 24, finished: false)
        }
        await stop(a)
        a = try await authenticated(d, file, accounts)
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        await a.replayProgress()
        try check(a.progressDisk.pending.isEmpty, "reread queue did not drain")
        for title in titles {
            for account in accounts.keys {
                let row = ProgressServer.state.withLock { $0.rows[account + ":" + title.key]! }
                try check(row["currentTime"] as? Double == 24 && row["progress"] as? Double == 0.24 && row["isFinished"] as? Bool == false, "reread lost remote position/progress: " + account + ":" + title.key)
            }
        }
        a = try await authenticated(d, file, accounts)
        for title in titles {
            try check(a.progressDisk.local[title.key]?.currentTime == 24 && a.pct(title.key) == 0.24, "reread readback lost durable position")
        }
    }


    static func scopeRegressions(_ book: Now) async throws {
        for change in ["user", "server"] {
            let suite = "scope-" + UUID().uuidString
            let d = UserDefaults(suiteName: suite)!
            let file = URL.temporaryDirectory.appending(path: suite + ".json")
            defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
            let origin = "http://abs-progress-fixture.invalid"
            d.set(origin, forKey: "server"); d.set("own", forKey: "me")
            let a = try await authenticated(d, file, ["own": Tok(a: "own", r: "own")])
            ProgressServer.state.withLock { s in
                s.offline = false
                s.rows["own:/api/me"] = ["mediaProgress": [["libraryItemId": book.item, "currentTime": 80.0, "lastUpdate": ms()]], "bookmarks": []]
            }
            await a.load("/api/me") { (m: Me) in a.setMe(m) }
            let cached = a.cached("/api/me")
            try check(cached != nil && a.progressDisk.local[book.key]?.currentTime == 80, "scope fixture failed to populate cache")
            let media = dlDir.appending(path: suite + ".fixture")
            try Data([1, 2, 3]).write(to: media)
            defer { try? FileManager.default.removeItem(at: media) }
            a.saveNow(book); d.set("80,9999999999999", forKey: "pos:" + book.key)
            a.fav = [Card(id: book.item, title: "Private A", sub: "")]
            a.favq = [book.item: true]; a.addHistory(book)
            ProgressServer.state.withLock { $0.reject = true }
            _ = try? await a.login(origin, "different", "fixture", main: true)
            try check(a.cached("/api/me") == cached && a.loadNow() == book && !a.favq.isEmpty, "failed login cleared account mirrors")
            ProgressServer.state.withLock { $0.reject = false }
            try check(a.cached("/api/me") == cached && a.loadNow() == book && !a.hist.isEmpty, "reauth fixture lost account mirrors")
            _ = try await a.login(origin, "own", "fixture", main: true)
            try check(a.cached("/api/me") == nil && a.loadNow() == book && a.hist.isEmpty, "reauth retained stale JSON/history or lost playback")
            ProgressServer.state.withLock { $0.holdGet = "/api/me" }
            let staleLoad = Task { await a.load("/api/me") { (m: Me) in a.setMe(m) } }
            try await wait { ProgressServer.state.withLock { $0.held != nil } }
            let oldLoad = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }!
            let name = change == "user" ? "different" : "own"
            _ = try await a.login(change == "server" ? "http://abs-progress-other.invalid" : origin, name, "fixture", main: true)
            oldLoad.respond()
            await staleLoad.value
            ProgressServer.state.withLock { $0.rows[name + ":/api/me"] = ["mediaProgress": [], "bookmarks": []] }
            // This is Home.load's real cached-then-fresh /me path, not a journal-only check.
            var renders = 0
            await a.load("/api/me") { (m: Me) in renders += 1; a.setMe(m) }
            try check(renders == 1 && a.progressDisk.local.isEmpty && a.progress.isEmpty, "old cached /me contaminated " + change)
            try check(FileManager.default.fileExists(atPath: media.path), "scope change deleted media")
            try check(a.loadNow() == nil && d.object(forKey: "pos:" + book.key) == nil && a.fav.isEmpty && a.favq.isEmpty && a.hist.isEmpty, "old account mirrors survived " + change)
            let reloaded = configured(defaults: d, progressFile: file, accounts: a.accts)
            ProgressServer.state.withLock { $0.offline = true }
            let ps = await reloaded.positions(book)
            try check(ps.first?.time == 0 && reloaded.progressDisk.local.isEmpty, "shared item resumed A after " + change)
        }
        ProgressServer.state.withLock { $0.offline = false }
    }

    static func acknowledgmentRegressions(_ book: Now) async throws {
        for observation in [false, true] {
            let suite = "ack-" + UUID().uuidString
            let d = UserDefaults(suiteName: suite)!
            let file = URL.temporaryDirectory.appending(path: suite + ".json")
            defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
            d.set("http://abs-progress-fixture.invalid", forKey: "server"); d.set("own", forKey: "me")
            let accounts = ["own": Tok(a: "own", r: "own")]
            var a = try await authenticated(d, file, accounts)
            let n = Now(item: suite, ep: nil, title: "Ack", author: "", tracks: book.tracks)
            ProgressServer.state.withLock { $0.offline = false; $0.holdPatch = true }
            a.push(n, 10, finished: false)
            try await wait { ProgressServer.state.withLock { $0.held != nil } }
            a.push(n, 60, finished: false)
            // Stop the background loop after this attempt, but allow successful readback.
            for i in a.progressDisk.pending.indices { a.progressDisk.pending[i].retryAt = ms() + 300000 }
            let held = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }!
            if observation {
                await stop(a) // uncertain acknowledgement / process death
                ProgressServer.state.withLock { $0.rows["own:" + n.key] = ["libraryItemId": n.item, "currentTime": 10.0, "isFinished": false, "lastUpdate": ms() + 1000] }
                a = try await authenticated(d, file, accounts)
                let ps = await a.positions(n)
                try check(ps.first?.time == 60, "uncertain send overwrote coalesced event")
            } else {
                held.respond()
                try await wait { a.progressDisk.pending.first?.acknowledged != nil }
                await stop(a)
            }
            try check(a.progressDisk.pending.first?.sent == nil && a.progressDisk.pending.first?.acknowledged != nil, "attempt did not resolve to exact ack")
            a = try await authenticated(d, file, accounts)
            let ack = a.progressDisk.pending[0].acknowledged!
            try check(a.progressDisk.local[n.key]?.currentTime == 60, "old ack replaced newer local event")
            ProgressServer.state.withLock { $0.rows["own:" + n.key] = ["libraryItemId": n.item, "currentTime": 10.0, "isFinished": false, "lastUpdate": ack.at + 2000] }
            let patches = ProgressServer.state.withLock { $0.patches }
            if observation {
                let ps = await a.positions(n)
                try check(ps.first?.time == 10, "new external identical payload was exempted on observation")
            } else { due(a); await a.replayProgress() }
            try check(a.progressDisk.pending.isEmpty && a.progressDisk.local[n.key]?.currentTime == 10 && ProgressServer.state.withLock { $0.patches } == patches, "new external identical payload overwritten")
        }
    }

    /// Owner cancellation must compose with account-scoped resume choices and disk replay.
    static func ownerRegressions(_ book: Now) async throws {
        let suite = "owner-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let origin = "http://abs-progress-fixture.invalid"
        d.set(origin, forKey: "server"); d.set("own", forKey: "me")
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        let a = try await authenticated(d, file, accounts)
        let p = Player(source: a), owner = UUID(), newerOwner = UUID()
        defer { p.clear(); a.progressTask?.cancel() }
        let n = Now(item: suite, ep: "episode", title: "Owner fixture", author: "", tracks: book.tracks)
        a.shares[n.item] = ["linked"]
        ProgressServer.state.withLock { s in
            s.offline = false
            s.rows["own:" + n.key] = ["libraryItemId": n.item, "episodeId": n.ep!, "currentTime": 0.0, "lastUpdate": 1.0]
            s.rows["linked:" + n.key] = ["libraryItemId": n.item, "episodeId": n.ep!, "currentTime": 70.0, "lastUpdate": 2.0]
        }
        // Cancelling a held HTTP load must settle its Loading state without rendering,
        // changing offline state, or caching account data after cancellation.
        let load = Loading(), loadPath = "/api/owner-loading-" + suite
        ProgressServer.state.withLock { state in
            state.holdGet = loadPath
            state.rows["own:" + loadPath] = ["mediaProgress": [], "bookmarks": []]
        }
        var renders = 0
        let loading = Task { await load.run { await a.load(loadPath) { (_: Me) in renders += 1 } } }
        try await wait("held owner load") { ProgressServer.state.withLock { $0.held != nil } }
        try check(load.busy, "held load did not expose busy state")
        load.cancel()
        await loading.value
        ProgressServer.state.withLock { $0.held = nil }
        try check(!load.busy && !load.finished && load.error == nil && renders == 0 && a.cached(loadPath) == nil && !a.offline, "cancelled load published/cache/error state")
        // A held position response also cannot commit after its screen leaves.
        ProgressServer.state.withLock { $0.holdGet = "/api/me/progress/" + n.key }
        let preparing = Task { await p.play(n, owner: owner) }
        try await wait("held owner positions") { ProgressServer.state.withLock { $0.held != nil } }
        p.cancelPreparation(owner: owner)
        let held = ProgressServer.state.withLock { state in let value = state.held; state.held = nil; return value }
        held?.respond()
        await preparing.value
        try check(p.now == nil && p.preparing == nil && p.choices == nil && a.loadNow() == nil, "cancelled position response committed")
        await p.play(n, owner: owner)
        guard let cancelled = p.choices else { throw Msg(errorDescription: "owner fixture missing choice") }
        p.cancelPreparation(owner: owner)
        p.resume(cancelled, at: 1)
        try check(p.now == nil && p.choices == nil && a.loadNow() == nil && a.hist.isEmpty, "cancelled resume choice committed")
        await p.play(n, owner: owner)
        guard let superseded = p.choices else { throw Msg(errorDescription: "owner fixture missing superseded choice") }
        await p.play(n, owner: newerOwner)
        guard let current = p.choices else { throw Msg(errorDescription: "owner fixture missing current choice") }
        p.cancelPreparation(owner: owner)
        p.resume(superseded, at: 1)
        try check(p.now == nil && p.choices?.request == current.request, "old owner cancelled/replayed newer choice")
        // Reauthentication preserves committed playback, never a pending resume choice.
        _ = try await a.login(origin, "own", "fixture", main: true)
        p.resume(current, at: 1)
        try check(p.now == nil && a.loadNow() == nil && a.hist.isEmpty, "reauthenticated stale resume choice committed")
        _ = try await a.login(origin, "linked", "fixture", main: false)
        a.shares[n.item] = ["linked"]
        await p.play(n, owner: newerOwner)
        guard let authenticatedChoice = p.choices else { throw Msg(errorDescription: "reauthenticated owner missing choice") }
        p.resume(authenticatedChoice, at: 1)
        ProgressServer.state.withLock { $0.offline = true }
        p.cancelPreparation(owner: newerOwner)
        try check(p.now == n && a.loadNow() == n && a.hist.count == 1 && p.preparing == nil, "owner cancellation revoked committed playback")
        // The committed episode's offline progress survives owner teardown and replays.
        p.clear()
        a.push(n, 74, finished: false)
        await stop(a)
        let restored = configured(defaults: d, progressFile: file, accounts: a.accts)
        try check(restored.progressDisk.pending.count == 2 && restored.progressDisk.local[n.key]?.currentTime == 74, "owner teardown lost scoped episode progress")
        due(restored)
        ProgressServer.state.withLock { $0.offline = false }
        await restored.replayProgress()
        try check(restored.progressDisk.pending.isEmpty && ProgressServer.state.withLock { $0.rows["linked:" + n.key]?["currentTime"] as? Double } == 74, "owner episode did not replay to linked account")
        await stop(restored)
    }

    static func preparationRegressions(_ book: Now) async throws {
        for change in ["user", "server", "logout"] {
            for path in ["play", "cachedCard", "item", "restore", "choices", "queue"] {
                let suite = "prepare-" + UUID().uuidString
                let d = UserDefaults(suiteName: suite)!
                let file = URL.temporaryDirectory.appending(path: suite + ".json")
                defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
                let origin = "http://abs-progress-fixture.invalid"
                d.set(origin, forKey: "server"); d.set("own", forKey: "me")
                let a = try await authenticated(d, file, ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")])
                let p = Player(source: a)
                let owner = UUID()
                let n = Now(item: suite, ep: nil, title: "Old title", author: "", tracks: book.tracks)
                let itemPath = "/api/items/" + n.item
                let item: [String: Any] = ["id": n.item, "media": ["metadata": ["title": n.title], "tracks": [["ino": "0", "duration": 100.0]]]]
                ProgressServer.state.withLock { s in
                    s.offline = false
                    s.rows["own:" + itemPath] = item
                    s.rows["own:" + n.key] = ["libraryItemId": n.item, "currentTime": 10.0, "lastUpdate": 1.0]
                    s.rows["linked:" + n.key] = ["libraryItemId": n.item, "currentTime": 70.0, "lastUpdate": 2.0]
                }
                if path == "cachedCard" { _ = try await a.get(itemPath + "?expanded=1") }
                var preparation: Task<Void, Never>?
                var choice: Player.ResumeChoices?
                if path == "choices" {
                    a.shares[n.item] = ["linked"]
                    await p.play(n, owner: owner)
                    choice = p.choices
                    try check(choice?.positions.count == 2, "resume choice fixture failed")
                } else if path == "queue" {
                    // Expired synthetic token forces the actual queue through an await.
                    a.accts["own"]!.a = "x.eyJleHAiOjB9.x"
                    ProgressServer.state.withLock { $0.holdRefresh = true }
                    p.start(n, 0, generation: a.playbackGeneration)
                } else {
                    a.saveNow(n)
                    ProgressServer.state.withLock { $0.holdGet = path == "item" ? itemPath : "/api/me/progress/" + n.key }
                    preparation = Task {
                        if path == "restore" { await p.restore() }
                        else if path == "item" || path == "cachedCard" { await p.playCard(Card(id: n.item, title: n.title, sub: ""), owner: owner) }
                        else { await p.play(n, owner: owner) }
                    }
                }
                if path != "choices" { try await wait { ProgressServer.state.withLock { $0.held != nil } } }
                let held = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
                if change == "logout" {
                    a.logout()
                    // Same user logging back in must not resurrect a pre-logout choice.
                    if path == "choices" { _ = try await a.login(origin, "own", "fixture", main: true) }
                }
                else { _ = try await a.login(change == "server" ? "http://abs-progress-other.invalid" : origin, change == "user" ? "different" : "own", "fixture", main: true) }
                held?.respond()
                await preparation?.value
                if let choice { p.resume(choice, at: 1) }
                try await Task.sleep(for: .milliseconds(20))
                try check((p.now == nil || path == "queue") && p.p.currentItem == nil && p.p.timeControlStatus == .paused, "stale preparation started: " + path + "/" + change)
                try check(a.loadNow() == nil && a.hist.isEmpty && a.progressDisk.local.isEmpty && a.progressDisk.pending.isEmpty, "stale preparation captured: " + path + "/" + change)
                p.clear()
                await stop(a)
            }
        }
    }

    static func run() async throws {
        print("Progress fixture phase: offline journal and reconnect")
        URLProtocol.registerClass(ProgressServer.self)
        ProgressServer.state.withLock { $0 = .init() }
        let suite = "progress-fixture-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("http://abs-progress-fixture.invalid", forKey: "server")
        d.set("own", forKey: "me")
        let file = URL.temporaryDirectory.appending(path: suite + "/progress.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        var a = try await authenticated(d, file, accounts)
        defer { a.progressTask?.cancel() }
        a.shares["pod"] = ["linked"]
        let book = Now(item: "book", ep: nil, title: "Fixture", author: "", tracks: [Track(ino: "0", ext: ".wav", size: 0, duration: 100, start: 0)])
        let ep1 = Now(item: "pod", ep: "one", title: "One", author: "", tracks: book.tracks)
        let ep2 = Now(item: "pod", ep: "two", title: "Two", author: "", tracks: book.tracks)
        ProgressServer.state.withLock { $0.offline = true }
        a.push(book, 20, finished: false)
        a.push(book, 35, finished: false) // pause coalesces periodic progress
        a.push(ep1, 100, finished: true)
        a.push(ep1, 100, finished: false) // late pause must not erase finish
        a.push(ep2, 48, finished: false)
        a.setMe(Me(mediaProgress: [], bookmarks: []))
        try check(a.pct(ep1.key) == 1, "cached /me erased finish")
        try check(a.progressDisk.pending.count == 5, "per-recipient/title/episode coalescing")
        try await wait { a.progressDisk.pending.allSatisfy { $0.attempts > 0 } }
        let before = ProgressServer.state.withLock { $0.requests }
        await a.replayProgress()
        try check(ProgressServer.state.withLock { $0.requests } == before, "backoff ignored")
        try check(PendingProgress.delay(1) == 2 && PendingProgress.delay(3) == 8 && PendingProgress.delay(10) == 300, "backoff bound")
        await stop(a)
        a = try await authenticated(d, file, accounts)
        try check(a.progressDisk.pending.count == 5 && a.pct(ep1.key) == 1, "restart lost outbox/finish: pending=\(a.progressDisk.pending.count), pct=\(String(describing: a.pct(ep1.key))), shares=\(a.shares)")
        let disk = try String(contentsOf: file, encoding: .utf8)
        try check(!disk.contains("accessToken") && !disk.contains("refreshToken") && !disk.contains("Bearer"), "credentials in outbox")
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        await a.ping() // reconnect trigger, no playback
        try await wait { a.progressDisk.pending.isEmpty }
        try check(ProgressServer.state.withLock { $0.rows["own:book"]?["currentTime"] as? Double } == 35, "book replay")
        try check(ProgressServer.state.withLock { $0.rows["linked:pod/one"]?["isFinished"] as? Bool } == true, "linked finish replay")
        try check(ProgressServer.state.withLock { $0.rows["own:pod/two"]?["currentTime"] as? Double } == 48, "episode identity")
        await stop(a)

        print("Progress fixture phase: reviewRegressions")
        try await reviewRegressions(book)
        print("Progress fixture phase: passiveCompletionRegressions")
        try await passiveCompletionRegressions(book)
        print("Progress fixture phase: rereadRegressions")
        try await rereadRegressions(book)
        print("Progress fixture phase: scopeRegressions")
        try await scopeRegressions(book)
        print("Progress fixture phase: acknowledgmentRegressions")
        try await acknowledgmentRegressions(book)
        print("Progress fixture phase: preparationRegressions")
        try await ownerRegressions(book)
        try await preparationRegressions(book)

        print("Progress fixture phase: in-flight replay, retries and revocation")
        // Newer local event arrives while the old first-create PATCH is held.
        ProgressServer.state.withLock { $0.holdPatch = true }
        let race = Now(item: "race", ep: nil, title: "Race", author: "", tracks: book.tracks)
        a.push(race, 10, finished: false)
        try await wait { ProgressServer.state.withLock { $0.held != nil } }
        a.push(race, 60, finished: false)
        let held = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
        held!.respond()
        try await wait { a.progressDisk.pending.isEmpty }
        try check(ProgressServer.state.withLock { $0.rows["own:race"]?["currentTime"] as? Double } == 60, "old ack deleted newer event")
        await stop(a)

        // Response lost after a first-create PATCH, then process replacement with a
        // newer local event. Persisted attempted payload recognizes our own row.
        let lost = Now(item: "lost", ep: nil, title: "Lost response", author: "", tracks: book.tracks)
        ProgressServer.state.withLock { $0.holdPatch = true }
        a.push(lost, 12, finished: false)
        try await wait { ProgressServer.state.withLock { $0.held != nil } }
        a.push(lost, 44, finished: false)
        let dropped = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
        a.progressTask?.cancel()
        await a.progressTask?.value
        ProgressServer.state.withLock { s in
            s.rows["own:lost"] = ["libraryItemId": "lost", "currentTime": 12.0, "isFinished": false, "lastUpdate": ms() + 1000]
        }
        _ = dropped // cancelled request deliberately never calls its URLProtocol client
        a = configured(defaults: d, progressFile: file, accounts: a.accts)
        let ownRow = try JSONDecoder().decode(Prog.self, from: JSONSerialization.data(withJSONObject: ProgressServer.state.withLock { $0.rows["own:lost"]! }))
        a.setMe(Me(mediaProgress: [ownRow], bookmarks: []))
        let ownPosition = await a.positions(lost)
        try check(ownPosition.first?.time == 44 && a.progressDisk.pending.count == 1, "read treated attempted first-create as external progress")
        due(a)
        await a.replayProgress()
        try check(ProgressServer.state.withLock { $0.rows["own:lost"]?["currentTime"] as? Double } == 44, "lost ack erased newer event on restart")

        // Independent newer remote state wins; linked progress is not overwritten.
        ProgressServer.state.withLock { $0.offline = true }
        a.push(ep2, 55, finished: false)
        await stop(a)
        ProgressServer.state.withLock { s in
            s.offline = false
            s.rows["linked:pod/two"] = ["libraryItemId": "pod", "episodeId": "two", "currentTime": 90, "lastUpdate": ms() + 5000]
        }
        due(a)
        await a.replayProgress()
        try check(ProgressServer.state.withLock { $0.rows["linked:pod/two"]?["currentTime"] as? Int } == 90, "remote-newer overwritten")

        // A reachable server can still fail a write; retain and retry it.
        ProgressServer.state.withLock { $0.failPatch = true }
        a.push(race, 75, finished: false)
        try await wait { a.progressDisk.pending.first?.attempts ?? 0 > 0 }
        await stop(a)
        ProgressServer.state.withLock { $0.failPatch = false }
        due(a)
        await a.replayProgress()
        try check(a.progressDisk.pending.isEmpty, "503 retry did not drain")

        // 401 refresh retry and failed refresh retain the queue, with bounded retry.
        ProgressServer.state.withLock { $0.reject = true; $0.failRefresh = true }
        a.push(book, 70, finished: false)
        try await wait { a.progressDisk.pending.first?.attempts ?? 0 > 0 }
        await stop(a)
        try check(!a.progressDisk.pending.isEmpty && a.expired, "auth failure dropped pending")
        ProgressServer.state.withLock { $0.failRefresh = false }
        due(a)
        a.startProgressReplay()
        try await wait { a.progressDisk.pending.isEmpty }
        try check(ProgressServer.state.withLock { $0.refreshes } >= 2, "401 did not refresh")
        await stop(a)

        // Revocation while a linked GET is in flight must prevent its PATCH.
        ProgressServer.state.withLock { $0.holdLinkedRead = true }
        a.push(ep1, 100, finished: true)
        try await wait { ProgressServer.state.withLock { $0.held != nil } }
        a.shares["pod"] = []
        let revoked = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
        let linkedBefore = ProgressServer.state.withLock { $0.rows["linked:pod/one"]?["lastUpdate"] as? Double }
        revoked!.respond()
        try await wait { a.progressDisk.pending.isEmpty }
        try check(ProgressServer.state.withLock { $0.rows["linked:pod/one"]?["lastUpdate"] as? Double } == linkedBefore, "revoked in-flight linked write")
        await stop(a)
        a.shares["pod"] = ["linked"]
        ProgressServer.state.withLock { $0.offline = true }
        a.push(ep1, 100, finished: true)
        a.push(ep2, 65, finished: false)
        a.shares["pod"] = []
        try check(a.progressDisk.pending.allSatisfy { $0.account == "own" }, "share removal failed")
        a.shares["pod"] = ["linked"]
        a.push(ep2, 66, finished: false)
        a.unlink("linked")
        try check(a.progressDisk.pending.allSatisfy { $0.account == "own" }, "unlink failed")
        print("Progress fixture phase: real player pause, completion and reread")
        // A real downloaded silent WAV drives AVQueuePlayer pause/end callbacks.
        // This also catches callbacks that accidentally still target the global app.
        let audioID = "progress-audio-" + UUID().uuidString
        let folder = a.mediaDir.appending(path: "audio/" + audioID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appending(path: "silent.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        do {
            let audio = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320000)!
            buffer.frameLength = 320000
            try audio.write(from: buffer)
        }
        // Leave enough media for asynchronous login/pause and reread assertions.
        // Seek near the end only when testing the real end notification. Real
        // duration and metadata agree, with rereads outside the last ten seconds.
        let track = Track(ino: "silent", ext: ".wav", size: a.size(wav), duration: 40, start: 0)
        let title = Now(item: audioID, ep: nil, title: "Silent fixture", author: "", tracks: [track])
        let playback = Player(source: a)
        playback.p.defaultRate = 1 // independent of the device's saved playback speed
        playback.start(title, 0, generation: a.playbackGeneration)
        try await wait("initial playback advances") { playback.pos > 0.3 }
        // Reauthentication invalidates old requests, not this same-account player.
        let playbackScope = a.playbackGeneration, requestScope = a.accountGeneration
        ProgressServer.state.withLock { $0.offline = false; $0.holdRefresh = true }
        let refreshingSource = a
        let staleRefresh = Task { try await refreshingSource.token(fresh: .infinity) }
        try await wait { ProgressServer.state.withLock { $0.held != nil } }
        let heldRefresh = ProgressServer.state.withLock { s in let p = s.held; s.held = nil; return p }
        _ = try await a.login(a.server, "own", "fixture", main: true)
        try check(a.playbackGeneration == playbackScope && a.accountGeneration != requestScope, "reauth changed playback scope or retained request scope")
        // Let the cancelled transport settle; then deliver its stale response.
        _ = try? await staleRefresh.value
        heldRefresh!.respond()
        try check(a.accts["own"]?.a == "own", "stale refresh replaced login credentials")
        ProgressServer.state.withLock { $0.offline = true }
        playback.p.pause()
        try await wait("same-account pause persists") { a.progressDisk.local[title.key]?.currentTime ?? 0 > 0 }
        let paused = try JSONDecoder().decode(ProgressDisk.self, from: Data(contentsOf: file))
        try check((paused.local[title.key]?.currentTime ?? 0) > 0 && paused.pending.contains { $0.key == title.key && !$0.finished }, "same-account reauth pause was not durable")
        let soughtEnd = await playback.p.seek(to: CMTime(seconds: 39, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        try check(soughtEnd, "could not seek to natural-end fixture segment")
        playback.play()
        try await wait("natural playback end persists") { a.progressDisk.local[title.key]?.isFinished == true }
        playback.clear()
        await stop(a)
        a = configured(defaults: d, progressFile: file, accounts: a.accts)
        try check(a.pct(title.key) == 1, "offline player finish lost after restart")
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        a.startProgressReplay()
        try await wait { a.progressDisk.pending.isEmpty }
        try check(ProgressServer.state.withLock { $0.rows["own:" + title.key]?["isFinished"] as? Bool } == true, "player finish not replayed")
        // Restoring a completed download must stay complete until explicit play.
        ProgressServer.state.withLock { $0.offline = true }
        let reread = Player(source: a)
        reread.p.defaultRate = 1
        await reread.restore()
        try check(a.pct(title.key) == 1, "passive restore cleared completion")
        try await wait("completed download restores paused") { reread.p.currentItem != nil }
        reread.play()
        try await wait("reread advances before end") { reread.pos > 0.3 }
        reread.p.pause()
        try await wait("reread pause persists unfinished position") { (a.progressDisk.local[title.key]?.currentTime ?? 0) > 0 && a.progressDisk.local[title.key]?.isFinished == false }
        let rereadTime = a.progressDisk.local[title.key]!.currentTime!
        try check(rereadTime < 30, "reread must pause before the media completion threshold")
        reread.clear()
        await stop(a)
        a = configured(defaults: d, progressFile: file, accounts: a.accts)
        let resumed = await a.positions(title)
        try check(resumed.first?.time == rereadTime && a.pct(title.key) != 1, "offline reread lost resume after relaunch")
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        await a.replayProgress()
        try check(ProgressServer.state.withLock { $0.rows["own:" + title.key]?["isFinished"] as? Bool } == false, "reread failed to clear remote completion")
        try check(ProgressServer.state.withLock { $0.rows["own:" + title.key]?["currentTime"] as? Double } == rereadTime && a.progressDisk.local[title.key]?.currentTime == rereadTime, "player reread lost replay position")
        // The actual old AVQueuePlayer keeps callbacks after a switch. None may
        // capture under a different user/server, or after logout + same-user login.
        for change in ["user", "server", "logout"] {
            print("Progress fixture phase: old player after " + change)
            // Each independent account fixture needs its own explicitly seeded local bytes.
            let local = a.file(title.item, track)
            if local != wav {
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: wav).write(to: local)
            }
            defer { if local != wav { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) } }
            let oldPlayer = Player(source: a)
            oldPlayer.p.defaultRate = 1
            oldPlayer.start(title, 0, generation: a.playbackGeneration)
            try await wait("old player advances before " + change) { oldPlayer.pos > 0.3 }
            ProgressServer.state.withLock { $0.offline = false }
            let oldServer = a.server, oldUser = a.me!
            if change == "logout" { a.logout() }
            _ = try await a.login(change == "server" ? "http://abs-progress-other.invalid" : oldServer,
                                  change == "user" ? "different" : oldUser, "fixture", main: true)
            ProgressServer.state.withLock { $0.offline = true }
            oldPlayer.p.pause()
            try await wait("old player pauses after " + change) { !oldPlayer.playing }
            oldPlayer.play()
            try await Task.sleep(for: .milliseconds(50))
            try check(oldPlayer.p.timeControlStatus == .paused, "old player resumed after " + change)
            try check(a.progressDisk.local[title.key] == nil && a.progressDisk.pending.isEmpty, "old player captured after " + change)
            oldPlayer.clear()
            await stop(a)
        }
        a.logout()
        await stop(a)
        let saved = try JSONDecoder().decode(ProgressDisk.self, from: Data(contentsOf: file))
        try check(saved.pending.isEmpty && saved.local.isEmpty, "logout retained private progress")
        ProgressServer.state.withLock { $0.offline = false }
        _ = try await a.login("http://abs-progress-fixture.invalid", "other", "fixture", main: true)
        let count = ProgressServer.state.withLock { $0.patches }
        await a.replayProgress()
        try check(ProgressServer.state.withLock { $0.patches } == count, "old queue crossed account scope")
    }
}
#endif
