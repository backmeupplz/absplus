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
        var holdPatch = false
        var holdLinkedRead = false
        var held: ProgressServer?
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs-progress-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let held = Self.state.withLock { s in
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
                return (200, ["user": ["username": name, "accessToken": name, "refreshToken": name]])
            }
            if s.reject { return (401, [:]) }
            let name = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            let key = name + ":" + path.replacingOccurrences(of: "/api/me/progress/", with: "")
            if request.httpMethod == "PATCH" {
                if s.failPatch { return (503, [:]) }
                s.patches += 1
                var row = json
                let parts = path.replacingOccurrences(of: "/api/me/progress/", with: "").split(separator: "/")
                row["libraryItemId"] = String(parts[0])
                if parts.count > 1 { row["episodeId"] = String(parts[1]) }
                // ABS first-row creation uses server time rather than lastUpdate.
                if s.rows[key] == nil { row["lastUpdate"] = ms() + 1000 }
                row["isFinished"] = (row["isFinished"] as? Bool ?? false) || (s.rows[key]?["isFinished"] as? Bool ?? false)
                s.rows[key] = row
                return (200, [:])
            }
            return s.rows[key].map { (200, $0) } ?? (404, [:])
        }
        if response.0 == -1 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response.1))
        client?.urlProtocolDidFinishLoading(self)
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
        let track = Track(ino: "silent", ext: ".wav", size: a.size(wav), duration: 3, start: 0)
        let title = Now(item: audioID, ep: nil, title: "Silent fixture", author: "", tracks: [track])
        let playback = Player(source: a)
        playback.start(title, 0)
        try await wait { playback.pos > 0.3 }
        playback.p.pause()
        try await wait { a.progressDisk.local[title.key]?.currentTime ?? 0 > 0 }
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
