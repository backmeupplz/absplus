#if DEBUG
import SwiftUI
import Network

/// Runs real queue/delegate paths on a disposable simulator, without credentials or personal media.
struct DownloadRetryFixture: View {
    @State private var result = "Running"
    private static let n = Now(item: "retry-fixture", ep: nil, title: "Retry fixture", author: "", tracks: [
        Track(ino: "one", ext: ".mp3", size: 7, duration: 60, start: 0),
        Track(ino: "two", ext: ".mp3", size: 7, duration: 60, start: 60)])
    var body: some View {
        VStack {
            Text(result).accessibilityIdentifier("retry-result")
            DlButton(n: Self.n)
            Text(dlStatus(Self.n))
        }.task { await run() }
    }

    @MainActor private func run() async {
        let n = Self.n, d = Downloader.shared
        if ProcessInfo.processInfo.arguments.contains("--retry-relaunch") {
            guard app.queued(n), app.dlRetry[app.rel(n.item, n.tracks[1])]?.attempts == 1,
                  app.done(n.item, n.tracks[0]), app.downloadWaiting(n) else { result = "Relaunch failed"; return }
            await app.resumeQueue() // persisted future deadline must prevent any network request
            guard app.inflight.isEmpty else { result = "Deadline ignored"; return }
            app.remove(n)
            result = "Relaunch passed"
            return
        }
        app.logout()
        app.d.set("http://retry-fixture.invalid", forKey: "server")
        app.me = "fixture"
        app.accts = ["fixture": Tok(a: "fixture", r: "")]
        app.remove(n)
        app.dlq = [n]
        let first = app.rel(n.item, n.tracks[0]), second = app.rel(n.item, n.tracks[1])
        let session = URLSession(configuration: .ephemeral)
        func task(_ rel: String, code: Int) -> RetryTask {
            let t = RetryTask()
            t.reply = HTTPURLResponse(url: URL(string: "http://retry-fixture.invalid/f")!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!
            d.bind(t, rel)
            return t
        }
        func success(_ rel: String) {
            let t = task(rel, code: 200)
            let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try! Data("fixture".utf8).write(to: temp)
            d.urlSession(session, downloadTask: t, didFinishDownloadingTo: temp)
            d.urlSession(session, task: t, didCompleteWithError: nil)
        }
        success(first)
        let failed = task(second, code: 503)
        d.urlSession(session, task: failed, didCompleteWithError: nil)
        assert(app.queued(n) && app.done(n.item, n.tracks[0]))
        assert(app.dlRetry[second]?.attempts == 1)
        assert(app.dlRetry[second]!.next!.timeIntervalSinceNow > 115)
        await app.resumeQueue()
        assert(app.inflight.isEmpty)
        let restored = Abs()
        assert(restored.queued(n) && restored.dlRetry[second]?.attempts == 1)
        success(second)
        assert(!app.queued(n) && app.done(n.item, n.tracks[0]) && app.done(n.item, n.tracks[1]))

        // Policy: bounded across serialization; numeric/date Retry-After and transport errors.
        let now = Date(timeIntervalSince1970: 0)
        assert(DownloadRetry.retryAfter("Thu, 01 Jan 1970 00:02:00 GMT", now: now) == 120)
        assert(DownloadRetry.retryAfter("nonsense", now: now) == 0)
        for code in [408, 429, 500, 503] {
            var r = DownloadRetry()
            for _ in 0..<5 { r.fail(nil, code: code, retryAfter: nil, now: now) }
            r = try! JSONDecoder().decode(DownloadRetry.self, from: JSONEncoder().encode(r))
            r.fail(nil, code: code, retryAfter: nil, now: now)
            assert(r.attempts == 5 && r.next == nil && r.error != nil)
        }
        assert(DownloadRetry.transient(URLError(.networkConnectionLost), code: 0))
        let sibling = Now(item: n.item, ep: "sibling", title: "Sibling", author: "", tracks: [Track(ino: "sibling", ext: ".mp3", size: 7, duration: 60, start: 0)])
        try! Data("fixture".utf8).write(to: app.file(sibling.item, sibling.tracks[0]))
        app.remove(n)
        assert(app.done(sibling.item, sibling.tracks[0]), "Cancel must preserve episode siblings")
        app.remove(sibling)
        app.dlq = [n]
        let permanent = task(second, code: 404)
        d.urlSession(session, task: permanent, didCompleteWithError: nil)
        assert(app.queued(n) && app.downloadError(n) != nil)

        // Late callbacks cannot remove or overwrite a replacement transfer of the same path.
        let old = task(second, code: 200)
        app.remove(n); app.dlq = [n]
        let replacement = task(second, code: 200)
        d.urlSession(session, task: old, didCompleteWithError: URLError(.cancelled))
        assert(app.transfers[second] == replacement.taskDescription && app.inflight.contains(second))
        let staleFile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! Data("fixture".utf8).write(to: staleFile)
        d.urlSession(session, downloadTask: old, didFinishDownloadingTo: staleFile)
        assert(!app.done(n.item, n.tracks[1]))
        try? FileManager.default.removeItem(at: staleFile)
        app.logout()
        d.urlSession(session, task: replacement, didCompleteWithError: URLError(.networkConnectionLost))
        assert(app.dlq.isEmpty && app.dlRetry.isEmpty && app.transfers.isEmpty)

        // Controlled local endpoint: real URLSession download returns 503 once, then 200.
        let server = try! RetryHTTPServer()
        await server.ready()
        app.d.set("http://127.0.0.1:\(server.port)", forKey: "server")
        app.me = "fixture"; app.accts = ["fixture": Tok(a: "fixture", r: "")]
        app.remove(n)
        await app.download(n)
        let end = Date().addingTimeInterval(15)
        while app.queued(n), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        assert(!app.queued(n), "503 should retry automatically without requeue")
        assert(app.done(n.item, n.tracks[0]) && app.done(n.item, n.tracks[1]))
        assert(server.counts["two"] == 2 && server.counts["one"] == 1)
        assert(server.secondAttempt.timeIntervalSince(server.firstAttempt) >= 1.8)
        server.stop()
        app.remove(n)

        // Persist a partial multi-file title for a real process termination/relaunch test.
        app.d.set("http://retry-fixture.invalid", forKey: "server")
        app.me = "fixture"; app.accts = ["fixture": Tok(a: "fixture", r: "")]
        app.dlq = [n]
        let cancelledID = app.queueID(n)!
        app.remove(n); app.dlq = [n]
        await app.fetch(n, queueID: cancelledID)
        assert(app.inflight.isEmpty, "A cancelled auth/retry continuation must not start a new queue incarnation")
        success(first)
        app.failed(second, nil, code: 429, retryAfter: "120")
        result = "Retry fixtures passed"
    }
}

private final class RetryTask: URLSessionDownloadTask, @unchecked Sendable {
    var reply: URLResponse?
    override var response: URLResponse? { reply }
}
#endif
