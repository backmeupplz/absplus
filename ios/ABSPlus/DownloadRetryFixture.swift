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

    /// Persist the exact gap between moving the final file and receiving its completion callback.
    @MainActor private func interruptedCompletion(seed: Bool) async {
        let n = Self.n, d = Downloader.shared
        if seed {
            app.logout()
            await login("http://retry-fixture.invalid")
            let paths = n.tracks.map { app.rel(n.item, $0) }
            app.remove(n); app.dlq = [n]
            let session = URLSession(configuration: .ephemeral)
            for (t, path) in zip(n.tracks, paths) {
                app.dlRetry[path] = DownloadRetry(attempts: 1, next: .distantPast)
                let task = RetryTask()
                task.reply = HTTPURLResponse(url: URL(string: "http://retry-fixture.invalid/f")!, statusCode: 200, httpVersion: nil, headerFields: nil)
                d.bind(task, path)
                let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try! Data("fixture".utf8).write(to: temp)
                d.urlSession(session, downloadTask: task, didFinishDownloadingTo: temp)
                // Deliberately omit didCompleteWithError: these identities have no system task.
                try! Data("stale resume".utf8).write(to: app.resumeFile(path))
                assert(app.done(n.item, t))
            }
            result = "Completion gap persisted"
            return
        }
        let paths = n.tracks.map { app.rel(n.item, $0) }
        assert(app.queued(n) && paths.allSatisfy { app.transfers[$0] != nil && app.dlRetry[$0]?.next != nil })
        assert(n.tracks.allSatisfy { app.done(n.item, $0) })
        let tasks = await d.session.allTasks
        assert(tasks.isEmpty, "No system task survives the interrupted completion")
        await d.restore()
        await app.resumeQueue()
        assert(app.dlq.isEmpty && app.dlRetry.isEmpty && app.transfers.isEmpty && app.inflight.isEmpty,
               "Completed titles and stale retries must settle after relaunch")
        assert(!app.downloadWaiting(n))
        let restored = Abs()
        assert(restored.dlq.isEmpty && restored.dlRetry.isEmpty && restored.transfers.isEmpty)
        for (t, path) in zip(n.tracks, paths) {
            assert(try! Data(contentsOf: app.file(n.item, t)) == Data("fixture".utf8))
            assert(!FileManager.default.fileExists(atPath: app.resumeFile(path).path))
        }
        let version = app.dlv
        try? await Task.sleep(for: .milliseconds(250))
        assert(app.dlv == version && app.dlq.isEmpty && app.dlRetry.isEmpty)
        // Fetch alone must also reconcile disk state, without resetting an unfinished sibling's budget.
        app.dlq = [n]
        let first = paths[0], second = paths[1]
        try! FileManager.default.removeItem(at: app.file(n.item, n.tracks[1]))
        app.dlRetry[first] = DownloadRetry(attempts: 1, next: .distantPast)
        let deadline = Date().addingTimeInterval(120)
        app.dlRetry[second] = DownloadRetry(attempts: 3, next: deadline)
        await app.fetch(n)
        assert(app.queued(n) && app.done(n.item, n.tracks[0]) && app.dlRetry[first] == nil)
        assert(app.dlRetry[second]?.attempts == 3 && app.dlRetry[second]?.next == deadline && app.inflight.isEmpty)
        try! Data("fixture".utf8).write(to: app.file(n.item, n.tracks[1]))
        await app.fetch(n)
        assert(app.dlq.isEmpty && app.dlRetry.isEmpty && app.inflight.isEmpty)
        let settled = app.dlv
        try? await Task.sleep(for: .milliseconds(250))
        assert(app.dlv == settled)
        app.remove(n)
        result = "Interrupted completion passed"
    }

    /// Select storage through the production successful-login boundary, never by writing preferences.
    @MainActor private func login(_ server: String) async {
        URLProtocol.registerClass(RetryLoginProtocol.self)
        _ = try! await app.login(server, "fixture", "fixture", main: true)
        assert(app.mediaDir.lastPathComponent != "locked")
    }

    @MainActor private func run() async {
        let n = Self.n, d = Downloader.shared
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--completion-seed") || arguments.contains("--completion-relaunch") {
            await interruptedCompletion(seed: arguments.contains("--completion-seed"))
            return
        }
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
        await login("http://retry-fixture.invalid")
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
        await login("http://127.0.0.1:\(server.port)")
        app.me = "fixture"; app.accts = ["fixture": Tok(a: "fixture", r: "")]
        app.remove(n)
        await app.download(n)
        let end = Date().addingTimeInterval(15)
        while app.queued(n), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        assert(!app.queued(n), "503 should retry automatically without requeue: counts=\(server.counts), retries=\(app.dlRetry), inflight=\(app.inflight)")
        assert(app.done(n.item, n.tracks[0]) && app.done(n.item, n.tracks[1]))
        assert(server.counts["two"] == 2 && server.counts["one"] == 1)
        assert(server.secondAttempt.timeIntervalSince(server.firstAttempt) >= 1.8)
        server.stop()
        app.remove(n)

        // Real refresh responses must preserve Retry-After through http -> token -> fetch.
        for code in [429, 503] {
            let auth = try! RetryHTTPServer()
            auth.refreshCode = code
            await auth.ready()
            await login("http://127.0.0.1:\(auth.port)")
            app.accts = ["fixture": Tok(a: "e30.eyJleHAiOjB9.", r: "refresh-fixture")]
            await app.download(n)
            for t in n.tracks {
                let r = app.dlRetry[app.rel(n.item, t)]!
                assert(r.attempts == 1 && r.next!.timeIntervalSinceNow > 115)
            }
            let first = app.rel(n.item, n.tracks[0])
            let restored = Abs()
            assert(restored.dlRetry[first]!.next!.timeIntervalSinceNow > 115)
            await app.resumeQueue()
            try? await Task.sleep(for: .seconds(2.2)) // the old 2-second path must not run
            assert(auth.counts["refresh"] == 1 && app.dlRetry[first]?.attempts == 1)
            assert(app.inflight.isEmpty && app.queued(n))
            app.remove(n); auth.stop()
        }

        // Suspend a real token-refresh response, then cancel/requeue or logout before releasing it.
        for logout in [false, true] {
            let auth = try! RetryHTTPServer()
            auth.holdRefresh = true
            await auth.ready()
            await login("http://127.0.0.1:\(auth.port)")
            app.me = "fixture"
            app.accts = ["fixture": Tok(a: "e30.eyJleHAiOjB9.", r: "refresh-fixture")]
            let pending = Task { await app.download(n) }
            await auth.waitFor("refresh")
            assert(app.inflight.isEmpty)
            if logout { app.logout() } else { app.remove(n); app.dlq = [n] }
            auth.release()
            await pending.value
            assert(app.inflight.isEmpty && app.transfers.isEmpty && app.dlRetry.isEmpty)
            assert(auth.counts["one"] == nil && auth.counts["two"] == nil)
            if logout { assert(app.me == nil && app.accts.isEmpty && app.dlq.isEmpty) }
            app.remove(n); auth.stop()
        }

        // Restore actual background tasks while the server holds responses; queue restart must not duplicate them.
        let held = try! RetryHTTPServer()
        held.holdFiles = true
        await held.ready()
        await login("http://127.0.0.1:\(held.port)")
        app.me = "fixture"; app.accts = ["fixture": Tok(a: "fixture", r: "")]
        await app.download(n)
        await held.waitFor("one"); await held.waitFor("two")
        let descriptions = app.transfers
        app.inflight = []; app.got = [:] // process-local view has not yet adopted the system tasks
        await d.restore()
        assert(app.inflight == Set(n.tracks.map { app.rel(n.item, $0) }) && app.transfers == descriptions)
        await app.resumeQueue()
        assert(app.transfers == descriptions)
        let live = await d.session.allTasks
        assert(live.filter { descriptions.values.contains($0.taskDescription ?? "") }.count == 2)
        app.remove(n)
        held.release(); held.stop()

        // Persist a partial multi-file title for a real process termination/relaunch test.
        await login("http://retry-fixture.invalid")
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

private final class RetryLoginProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/login" && ["retry-fixture.invalid", "127.0.0.1"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"user":{"username":"fixture","accessToken":"fixture"}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RetryTask: URLSessionDownloadTask, @unchecked Sendable {
    var reply: URLResponse?
    override var response: URLResponse? { reply }
}
#endif
