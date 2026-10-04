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
        // UI observation may empty dlq between didFinish and didComplete.
        Downloader.shared.urlSession(URLSession.shared, downloadTask: replacement, didFinishDownloadingTo: temp)
        app.dlChanged()
        try check(!app.queued(n), "completed title not removed")
        Downloader.shared.urlSession(URLSession.shared, task: replacement, didCompleteWithError: nil)
        try check(!app.inflight.contains(replacementRel) && app.got[replacementRel] == nil && app.transfers[replacementRel] == nil, "terminal callback leaked state after queue removal")
        app.remove(n)
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
        if request.url?.query == "expanded=1" { Self.itemRequests.withLock { $0 += 1 } }
        let flags = Self.state.withLock { $0 }
        if flags.1 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let login = request.url!.path == "/login"
        let pod = request.url!.path.hasSuffix("/pod")
        let audio: [String: Any] = ["ino": "1", "duration": 1, "metadata": ["ext": ".wav", "size": Self.audio.count], "token": "secret"]
        let media: [String: Any] = pod
            ? ["metadata": ["title": "Fixture Podcast", "author": "Author"], "episodes": [["id": "ep", "title": "Episode", "audioFile": audio]]]
            : ["metadata": ["title": "Fixture Book", "authorName": "Author"], "tracks": [audio]]
        let body: [String: Any] = login ? ["user": ["username": "fixture", "accessToken": "fixture"]]
            : ["id": pod ? "pod" : "book", "mediaType": pod ? "podcast" : "book", "media": media, "token": "secret"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: flags.0 ? 401 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
