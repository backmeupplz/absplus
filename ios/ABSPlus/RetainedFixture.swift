#if DEBUG
import SwiftUI
import AVFoundation
import os

/// Synthetic responses and generated silent audio only; no credentials or personal library.
struct RetainedFixture: View {
    @State private var result = "Running retained checks"
    var body: some View {
        Text(result).accessibilityIdentifier("retained-result").task {
            do { try await run(); result = "Retained checks passed" }
            catch { result = "Failed: " + error.localizedDescription }
        }
    }
    @MainActor private func run() async throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw Msg(errorDescription: message) } }
        URLProtocol.registerClass(RetainedProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetainedProtocol.self]
        app.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
        app.logout()
        let fm = FileManager.default
        // Fixture owns only the two synthetic server scopes.
        RetainedProtocol.state.withLock { $0 = (false, false) }
        let a = "http://retained-a.invalid", b = "http://retained-b.invalid"
        try await app.login(a, "fixture", "fixture", main: true)
        try? fm.removeItem(at: app.mediaDir)
        for id in ["book", "pod"] {
            _ = try await app.get("/api/items/\(id)?expanded=1")
            let it = try await app.item(id)
            let t = it.media.tracks?.first?.track() ?? it.media.episodes!.first!.audioFile!.track(0)
            let dst = app.file(id, t)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RetainedProtocol.audio.write(to: dst)
        }
        app.dlChanged()
        try check(app.downloaded("book") && app.downloaded("pod"), "initial download flags")
        let original = app.mediaDir
        let oldEpoch = app.mediaEpoch
        let track = try await app.item("book").media.tracks![0].track()
        let rel = app.rel("late", track)
        let late = RetainedDownloadTask()
        Downloader.shared.bind(late, rel)
        app.dlq = [Now(item: "late", ep: nil, title: "Late", author: "Fixture", tracks: [track])]
        app.inflight.insert(rel)
        app.logout()
        try check(app.me == nil && app.accts.isEmpty && app.downloads().isEmpty, "logout must lock retained media")
        try check(app.cached("/api/items/book?expanded=1") == nil, "logged-out metadata")
        RetainedProtocol.state.withLock { $0.0 = true }
        do { try await app.login(a, "fixture", "bad", main: true); throw Msg(errorDescription: "failed login accepted") }
        catch is HttpErr {} catch let e as Msg where e.errorDescription == "Wrong username or password" {}
        try check(app.downloads().isEmpty, "failed login unlocked media")
        RetainedProtocol.state.withLock { $0.0 = false }
        try await app.login(b, "fixture", "fixture", main: true)
        try? fm.removeItem(at: app.mediaDir)
        try check(app.downloads().isEmpty && !app.done("book", track), "cross-server media")
        app.logout()
        try await app.login(a + "/", "fixture", "fixture", main: true)
        try check(app.mediaDir == original && app.mediaEpoch != oldEpoch, "same-server selection")
        app.dlq = [Now(item: "late", ep: nil, title: "Late", author: "Fixture", tracks: [track])]
        app.inflight.insert(rel)
        let temp = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try RetainedProtocol.audio.write(to: temp)
        Downloader.shared.urlSession(URLSession.shared, downloadTask: late, didFinishDownloadingTo: temp)
        try check(!fm.fileExists(atPath: dlDir.appending(path: rel).path), "late completion wrote media")
        try? fm.removeItem(at: temp)
        // Cancel/requeue within one login: an old transfer cannot touch its replacement.
        let n = Now(item: "replacement", ep: nil, title: "Replacement", author: "Fixture", tracks: [track])
        let replacementRel = app.rel(n.item, track)
        let old = RetainedDownloadTask()
        let replacement = RetainedDownloadTask()
        app.dlq = [n]
        Downloader.shared.bind(old, replacementRel)
        app.remove(n)
        app.dlq = [n]
        Downloader.shared.bind(replacement, replacementRel)
        app.got[replacementRel] = 123
        let description = replacement.taskDescription
        try RetainedProtocol.audio.write(to: temp)
        Downloader.shared.urlSession(URLSession.shared, downloadTask: old, didFinishDownloadingTo: temp)
        Downloader.shared.urlSession(URLSession.shared, task: old, didCompleteWithError: URLError(.timedOut))
        try check(!app.done(n.item, track), "cancelled transfer overwrote replacement")
        try check(app.inflight.contains(replacementRel) && app.got[replacementRel] == 123 && app.transfers[replacementRel] == description && app.queued(n), "old completion changed replacement state")
        // Completed bytes remain queued until their live transfer reports completion.
        Downloader.shared.urlSession(URLSession.shared, downloadTask: replacement, didFinishDownloadingTo: temp)
        app.dlChanged()
        try check(app.done(n.item, track) && app.queued(n), "live completion lost its queue owner")
        Downloader.shared.urlSession(URLSession.shared, task: replacement, didCompleteWithError: nil)
        try check(!app.queued(n) && !app.inflight.contains(replacementRel) && app.got[replacementRel] == nil && app.transfers[replacementRel] == nil, "terminal callback leaked state after queue removal")
        // Even explicit queue pruning must not leak terminal transfer state.
        app.dlq = [n]
        Downloader.shared.bind(replacement, replacementRel)
        app.dlq = []
        Downloader.shared.urlSession(URLSession.shared, task: replacement, didCompleteWithError: nil)
        try check(app.transfers[replacementRel] == nil && !app.inflight.contains(replacementRel), "pruned queue leaked transfer")
        app.remove(n)
        try await cancellationChecks(track, a)
        let requestsBefore = RetainedProtocol.itemRequests.withLock { $0 }
        // No item request is permitted from here onward, even though login just succeeded.
        RetainedProtocol.state.withLock { $0.1 = true }
        app.offline = true
        try check(Set(app.downloads().map(\.id)) == ["book", "pod"], "offline index")
        try check(app.cachedCard("book").title == "Fixture Book" && app.cachedCard("pod").title == "Fixture Podcast", "retained cards")
        let safe = String(data: app.cached("/api/items/book?expanded=1")!, encoding: .utf8)!
        try check(!safe.contains("secret") && !safe.contains("token"), "unsafe metadata retained")
        for id in ["book", "pod"] {
            let it = try await app.item(id)
            let t = it.media.tracks?.first?.track() ?? it.media.episodes!.first!.audioFile!.track(0)
            try check(app.downloaded(id) && app.url(id, t).isFileURL, "offline media resolution")
            let audio = try AVAudioPlayer(contentsOf: app.url(id, t))
            try check(audio.prepareToPlay() && audio.play(), "native local audio playback")
            audio.stop()
        }
        // Exercise production AVQueuePlayer construction as well as the native decoder.
        let book = try await app.item("book")
        let now = Now(item: book.id, ep: nil, title: book.card.title, author: book.card.sub, tracks: book.media.tracks!.map { $0.track() })
        player.start(now, 0, play: false)
        for _ in 0..<40 where player.p.currentItem == nil { try await Task.sleep(for: .milliseconds(50)) }
        guard let asset = player.p.currentItem?.asset as? AVURLAsset else { throw Msg(errorDescription: "production playback queue empty") }
        try check(asset.url == app.url(now.item, now.tracks[0]), "production player did not resolve retained audio")
        let playable = try await asset.load(.isPlayable)
        try check(playable, "production asset is not playable")
        player.p.removeAllItems()
        player.now = nil
        try check(RetainedProtocol.itemRequests.withLock { $0 } == requestsBefore, "offline playback requested item metadata")
        let reconstructed = Abs()
        try check(reconstructed.downloaded("book") && reconstructed.downloaded("pod"), "restart retained scope")
        app.logout()
    }

    @MainActor private func cancellationChecks(_ track: Track, _ server: String) async throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw Msg(errorDescription: message) } }
        func expireToken() {
            app.accts["fixture"]!.a = "fixture.eyJleHAiOjB9.signature"
            app.accts["fixture"]!.r = "fixture"
        }
        func waitForRefresh(_ stage: String) async throws {
            for _ in 0..<500 {
                if RetainedProtocol.refresh.withLock({ $0.pending != nil }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Msg(errorDescription: "refresh did not suspend: " + stage)
        }
        func releaseRefresh() {
            let pending = RetainedProtocol.refresh.withLock { state in
                let pending = state.pending; state = (false, nil); return pending
            }
            pending?.respond()
        }
        defer { releaseRefresh() }
        let n = Now(item: "auth-cancel", ep: nil, title: "Auth cancel", author: "Fixture", tracks: [track])
        let rel = app.rel(n.item, track)
        // Exercise the real token refresh suspension, both removal and same-key requeue.
        for requeue in [false, true] {
            expireToken()
            RetainedProtocol.refresh.withLock { $0 = (true, nil) }
            let pending = Task { await app.download(n) }
            try await waitForRefresh("explicit cancellation, requeue=\(requeue)")
            let oldID = app.queueID(n)
            app.remove(n)
            if requeue { app.dlq.append(n); try check(app.queueID(n) != oldID, "requeue reused request identity") }
            releaseRefresh()
            await pending.value
            try check(app.transfers[rel] == nil && !app.inflight.contains(rel) && !app.done(n.item, track), "cancelled refresh started a transfer")
            app.remove(n)
        }

        let retry = Now(item: "retry-budget", ep: nil, title: "Retry", author: "Fixture", tracks: [track])
        let rr = app.rel(retry.item, track)
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: ["NSURLSessionDownloadTaskResumeData": Data([0])])
        func failTransfer() {
            let task = RetainedDownloadTask()
            Downloader.shared.bind(task, rr)
            Downloader.shared.urlSession(URLSession.shared, task: task, didCompleteWithError: failure)
        }
        // No await in this loop: cancellation happens before the scheduled retry gets a turn.
        for _ in 0..<5 {
            app.dlq.append(retry)
            failTransfer()
            try check(app.queued(retry) && app.dlRetry[rr]?.attempts == 1, "fresh cancellation attempt inherited retry budget")
            app.remove(retry)
        }
        app.dlq.append(retry)
        for _ in 0..<20 { await Task.yield() }
        try check(app.transfers[rr] == nil && !app.inflight.contains(rr), "scheduled old retry claimed a requeued title")
        // Automatic retries within one queue identity still exhaust their original budget.
        for attempt in 1...5 { failTransfer(); try check(app.queued(retry) && app.dlRetry[rr]?.attempts == attempt && app.downloadError(retry) == nil, "automatic retry stopped early") }
        failTransfer()
        try check(app.queued(retry) && app.dlRetry[rr]?.attempts == 5 && app.dlRetry[rr]?.next == nil && app.downloadError(retry) != nil, "automatic retries lost their bounded budget")
        app.remove(retry)

        // An admitted retry can itself suspend in authentication and then be cancelled.
        app.dlq.append(retry)
        expireToken()
        RetainedProtocol.refresh.withLock { $0 = (true, nil) }
        failTransfer()
        app.dlRetry[rr]!.next = .distantPast
        let pendingRetry = Task { await app.resumeQueue() }
        try await waitForRefresh("retry cancellation")
        app.remove(retry)
        app.dlq.append(retry)
        releaseRefresh()
        // Join the refresh, rather than guessing when its token write has completed.
        await pendingRetry.value
        try check(app.transfers[rr] == nil && !app.inflight.contains(rr), "retry resumed after cancellation during authentication")
        app.remove(retry)

        // Same-host successful main login replaces a session even without logout.
        for _ in 0..<5 {
            app.dlq.append(retry)
            expireToken()
            RetainedProtocol.refresh.withLock { $0 = (true, nil) }
            failTransfer()
            try check(app.queued(retry) && app.dlRetry[rr]?.attempts == 1, "relogin inherited retry budget")
            app.dlRetry[rr]!.next = .distantPast
            let pendingRetry = Task { await app.resumeQueue() }
            try await waitForRefresh("same-host replacement")
            try await app.login(server, "fixture", "fixture", main: true)
            releaseRefresh()
            await pendingRetry.value
            try check(app.dlq.isEmpty && app.transfers.isEmpty && !app.inflight.contains(rr), "relogin revived old retry")
        }
    }
}

/// Delegate fixtures need a successful response, like a real completed download.
private final class RetainedDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    override var response: URLResponse? {
        HTTPURLResponse(url: URL(string: "http://retained-a.invalid/audio")!, statusCode: 200, httpVersion: nil, headerFields: nil)
    }
}

final class RetainedProtocol: URLProtocol, @unchecked Sendable {
    static let itemRequests = OSAllocatedUnfairLock(initialState: 0)
    static let state = OSAllocatedUnfairLock(initialState: (false, false)) // fail login, offline
    static let refresh = OSAllocatedUnfairLock(initialState: (blocked: false, pending: Optional<RetainedProtocol>.none))
    static let audio: Data = {
        var d = Data()
        func text(_ s: String) { d.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        text("RIFF"); u32(16036); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        text("data"); u32(16000); d.append(Data(count: 16000)); return d
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("retained-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/auth/refresh", Self.refresh.withLock({ state in
            if state.blocked { state.pending = self; return true }
            return false
        }) { return }
        respond()
    }
    func respond() {
        if request.url?.query == "expanded=1" { Self.itemRequests.withLock { $0 += 1 } }
        let flags = Self.state.withLock { $0 }
        if flags.1 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let login = ["/login", "/auth/refresh"].contains(request.url!.path)
        let pod = request.url!.path.hasSuffix("/pod")
        let audio: [String: Any] = ["ino": "1", "duration": 1, "metadata": ["ext": ".wav", "size": Self.audio.count], "token": "secret"]
        let media: [String: Any] = pod
            ? ["metadata": ["title": "Fixture Podcast", "author": "Author"], "episodes": [["id": "ep", "title": "Episode", "audioFile": audio]]]
            : ["metadata": ["title": "Fixture Book", "authorName": "Author"], "tracks": [audio]]
        let body: [String: Any] = login ? ["user": ["id": "retained-fixture-id", "username": "fixture", "accessToken": "fixture"]]
            : ["id": pod ? "pod" : "book", "mediaType": pod ? "podcast" : "book", "media": media, "token": "secret"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: flags.0 ? 401 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
