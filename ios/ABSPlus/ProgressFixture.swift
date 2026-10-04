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
                return (200, ["user": ["username": name, "accessToken": name, "refreshToken": name]])
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
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Msg(errorDescription: "Timed out waiting for controlled request")
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
        let a = Abs(defaults: d, progressFile: file, accounts: ["own": Tok(a: "own", r: "own")])
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

    static func reviewRegressions(_ book: Now) async throws {
        let suite = "progress-review-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let origin = "http://abs-progress-fixture.invalid", other = "http://abs-progress-other.invalid"
        d.set(origin, forKey: "server"); d.set("own", forKey: "me")
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        var a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
        a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
        a = Abs(defaults: d, progressFile: file, accounts: accounts)
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

    static func rereadRegressions(_ book: Now) async throws {
        let suite = "progress-reread-" + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("http://abs-progress-fixture.invalid", forKey: "server"); d.set("own", forKey: "me")
        let file = URL.temporaryDirectory.appending(path: suite + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let accounts = ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")]
        var a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
        a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
        a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
            let a = Abs(defaults: d, progressFile: file, accounts: ["own": Tok(a: "own", r: "own")])
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
            _ = try await a.login(origin, "own", "fixture", main: true)
            try check(a.cached("/api/me") == cached && a.loadNow() == book && !a.hist.isEmpty, "reauth cleared account mirrors")
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
            let reloaded = Abs(defaults: d, progressFile: file, accounts: a.accts)
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
            var a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
                a = Abs(defaults: d, progressFile: file, accounts: accounts)
                let ps = await a.positions(n)
                try check(ps.first?.time == 60, "uncertain send overwrote coalesced event")
            } else {
                held.respond()
                try await wait { a.progressDisk.pending.first?.acknowledged != nil }
                await stop(a)
            }
            try check(a.progressDisk.pending.first?.sent == nil && a.progressDisk.pending.first?.acknowledged != nil, "attempt did not resolve to exact ack")
            a = Abs(defaults: d, progressFile: file, accounts: accounts)
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

    static func preparationRegressions(_ book: Now) async throws {
        for change in ["user", "server", "logout"] {
            for path in ["play", "cachedCard", "item", "restore", "choices", "queue"] {
                let suite = "prepare-" + UUID().uuidString
                let d = UserDefaults(suiteName: suite)!
                let file = URL.temporaryDirectory.appending(path: suite + ".json")
                defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
                let origin = "http://abs-progress-fixture.invalid"
                d.set(origin, forKey: "server"); d.set("own", forKey: "me")
                let a = Abs(defaults: d, progressFile: file, accounts: ["own": Tok(a: "own", r: "own"), "linked": Tok(a: "linked", r: "linked")])
                let p = Player(source: a)
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
                    await p.play(n)
                    choice = p.choices
                    try check(choice?.positions.count == 2, "resume choice fixture failed")
                } else if path == "queue" {
                    // Expired synthetic token forces the actual queue through an await.
                    a.accts["own"] = Tok(a: "x.eyJleHAiOjB9.x", r: "own")
                    ProgressServer.state.withLock { $0.holdRefresh = true }
                    p.start(n, 0, generation: a.playbackGeneration)
                } else {
                    a.saveNow(n)
                    ProgressServer.state.withLock { $0.holdGet = path == "item" ? itemPath : "/api/me/progress/" + n.key }
                    preparation = Task {
                        if path == "restore" { await p.restore() }
                        else if path == "item" || path == "cachedCard" { await p.playCard(Card(id: n.item, title: n.title, sub: "")) }
                        else { await p.play(n) }
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
        var a = Abs(defaults: d, progressFile: file, accounts: accounts)
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
        a = Abs(defaults: d, progressFile: file, accounts: accounts)
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

        try await reviewRegressions(book)
        try await rereadRegressions(book)
        try await scopeRegressions(book)
        try await acknowledgmentRegressions(book)
        try await preparationRegressions(book)

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
        a = Abs(defaults: d, progressFile: file, accounts: a.accts)
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
        // A real downloaded silent WAV drives AVQueuePlayer pause/end callbacks.
        // This also catches callbacks that accidentally still target the global app.
        let audioID = "progress-audio-" + UUID().uuidString
        let folder = dlDir.appending(path: audioID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appending(path: "silent.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        do {
            let audio = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
            buffer.frameLength = 24000
            try audio.write(from: buffer)
        }
        // The short WAV ends naturally; metadata stays >10s so rereads do not
        // immediately hit ABS's default finished-within-ten-seconds threshold.
        let track = Track(ino: "silent", ext: ".wav", size: a.size(wav), duration: 100, start: 0)
        let title = Now(item: audioID, ep: nil, title: "Silent fixture", author: "", tracks: [track])
        let playback = Player(source: a)
        playback.start(title, 0, generation: a.playbackGeneration)
        try await wait { playback.pos > 0.3 }
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
        try await wait { a.progressDisk.local[title.key]?.currentTime ?? 0 > 0 }
        let paused = try JSONDecoder().decode(ProgressDisk.self, from: Data(contentsOf: file))
        try check((paused.local[title.key]?.currentTime ?? 0) > 0 && paused.pending.contains { $0.key == title.key && !$0.finished }, "same-account reauth pause was not durable")
        playback.play()
        try await wait { a.progressDisk.local[title.key]?.isFinished == true }
        playback.clear()
        await stop(a)
        a = Abs(defaults: d, progressFile: file, accounts: a.accts)
        try check(a.pct(title.key) == 1, "offline player finish lost after restart")
        due(a)
        ProgressServer.state.withLock { $0.offline = false }
        a.startProgressReplay()
        try await wait { a.progressDisk.pending.isEmpty }
        try check(ProgressServer.state.withLock { $0.rows["own:" + title.key]?["isFinished"] as? Bool } == true, "player finish not replayed")
        // Restoring a completed download must stay complete until explicit play.
        ProgressServer.state.withLock { $0.offline = true }
        let reread = Player(source: a)
        await reread.restore()
        try check(a.pct(title.key) == 1, "passive restore cleared completion")
        try await wait { reread.p.currentItem != nil }
        reread.play()
        try await wait { reread.pos > 0.3 && reread.pos < 2 }
        reread.p.pause()
        try await wait { (a.progressDisk.local[title.key]?.currentTime ?? 0) > 0 && a.progressDisk.local[title.key]?.isFinished == false }
        let rereadTime = a.progressDisk.local[title.key]!.currentTime!
        reread.clear()
        await stop(a)
        a = Abs(defaults: d, progressFile: file, accounts: a.accts)
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
            let oldPlayer = Player(source: a)
            oldPlayer.start(title, 0, generation: a.playbackGeneration)
            try await wait { oldPlayer.pos > 0.3 }
            ProgressServer.state.withLock { $0.offline = false }
            let oldServer = a.server, oldUser = a.me!
            if change == "logout" { a.logout() }
            _ = try await a.login(change == "server" ? "http://abs-progress-other.invalid" : oldServer,
                                  change == "user" ? "different" : oldUser, "fixture", main: true)
            ProgressServer.state.withLock { $0.offline = true }
            oldPlayer.p.pause()
            try await wait { !oldPlayer.playing }
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
        a.me = "other"
        a.accts["other"] = Tok(a: "other", r: "other")
        ProgressServer.state.withLock { $0.offline = false }
        let count = ProgressServer.state.withLock { $0.patches }
        await a.replayProgress()
        try check(ProgressServer.state.withLock { $0.patches } == count, "old queue crossed account scope")
    }
}
#endif
