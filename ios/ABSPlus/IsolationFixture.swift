#if DEBUG
import SwiftUI
import os
import AVFoundation

struct IsolationFixture: View {
    @State private var result = "Running isolation checks"
    var body: some View {
        Text(result).accessibilityIdentifier("isolation-result").task {
            do { try await run(); result = "Isolation checks passed" }
            catch { result = "Failed: " + error.localizedDescription }
        }
    }
    @MainActor private func run() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw Msg(errorDescription: message) } }
        func wait(_ path: String) async throws {
            for _ in 0..<200 {
                if IsolationProtocol.state.withLock({ $0.pending.contains(where: { $0.request.url?.path == path }) }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Msg(errorDescription: "Request did not start: " + path)
        }
        func release() { IsolationProtocol.release() }
        func hold(_ path: String) {
            IsolationProtocol.state.withLock { $0.hold = path }
        }
        let a = "http://isolation-a.invalid", b = "http://isolation-b.invalid"
        URLProtocol.registerClass(IsolationProtocol.self)
        app.logout()
        // Session was constructed by another fixture? Always use this disposable protocol.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IsolationProtocol.self]
        app.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
        for bUser in ["same", "different"] {
            try await app.login(a, "same", "fixture", main: true)
            try await app.login(a, "linked", "fixture", main: false)
            app.shares = ["old": ["linked"]]; app.favq = ["old": true]
            app.fav = [Card(id: "old", title: "Old", sub: "")]
            app.d.set("12,1", forKey: "pos:old")
            let epoch = app.mediaEpoch
            IsolationProtocol.state.withLock { $0.failLogin = true }
            do { try await app.login(b, bUser, "bad", main: true); throw Msg(errorDescription: "Failed candidate committed") }
            catch let e as Msg where e.errorDescription == "Wrong username or password" {}
            IsolationProtocol.state.withLock { $0.failLogin = false }
            try check(app.server == a && app.mediaEpoch == epoch && app.accounts == ["linked"], "failed candidate changed session")
            hold("/login")
            let cancelled = Task { try await app.login(b, bUser, "fixture", main: true) }
            try await wait("/login"); cancelled.cancel(); release()
            _ = try? await cancelled.value
            try check(app.server == a && app.mediaEpoch == epoch, "cancelled login committed")
            app.accts["same"]!.a = "x.eyJleHAiOjB9.x"
            IsolationProtocol.state.withLock { $0.refresh401 = true }
            do { _ = try await app.token(); throw Msg(errorDescription: "Refresh did not expire") }
            catch is Expired { app.say(Expired()) }
            try check(app.expired, "401 did not expire A")
            try await app.login(b, bUser, "fixture", main: true)
            app.unlink("linked")
            _ = try await app.api("GET", "/api/me")
            try check(app.server == b && app.me == bUser && app.accts.count == 1 && app.accounts.isEmpty, "old account survived")
            try check(app.shares.isEmpty && app.fav.isEmpty && app.favq.isEmpty && app.progress.isEmpty && app.d.string(forKey: "pos:old") == nil && player.now == nil, "old state survived")
            try check(!app.expired && !app.offline, "old session flags survived")
            let restored = Abs()
            try check(restored.server == b && restored.me == bUser && restored.accts.count == 1 && restored.accts[bUser]?.host == b && restored.accounts.isEmpty, "host binding did not survive restart")
            IsolationProtocol.state.withLock { $0.refresh401 = false }
        }
        // Delayed refresh, read, linked login, and candidate login cannot resurrect A.
        for path in ["/auth/refresh", "/api/stale", "/login"] {
            try await app.login(a, "same", "fixture", main: true)
            if path == "/auth/refresh" { app.accts["same"]!.a = "x.eyJleHAiOjB9.x" }
            hold(path)
            var rendered = false
            let pending = Task {
                do {
                    if path == "/auth/refresh" { _ = try await app.token() }
                    else if path == "/login" { _ = try await app.login(a, "linked", "fixture", main: false) }
                    else { await app.load(path) { (_: Me) in rendered = true } }
                } catch { app.say(error) }
            }
            try await wait(path)
            IsolationProtocol.state.withLock { $0.hold = nil }
            try await app.login(b, "same", "fixture", main: true)
            release(); await pending.value
            try check(app.server == b && app.accts.count == 1 && app.accts["same"]?.host == b && !rendered && app.cached("/api/stale") == nil && !app.expired && app.toast == nil && !app.offline, "stale callback: " + path)
        }
        try await app.login(a, "same", "fixture", main: true)
        hold("/login")
        let oldLogin = Task { try await app.login(a, "old", "fixture", main: true) }
        try await wait("/login")
        IsolationProtocol.state.withLock { $0.hold = nil }
        try await app.login(b, "new", "fixture", main: true)
        release(); _ = try? await oldLogin.value
        try check(app.me == "new" && app.server == b, "late main login replaced new session")
        // Unlink while a refresh is suspended: no token resurrection or follow-up API.
        try await app.login(b, "linked", "fixture", main: false)
        app.accts["linked"]!.a = "x.eyJleHAiOjB9.x"
        hold("/auth/refresh")
        let refresh = Task { try await app.api("GET", "/api/linked", name: "linked") }
        try await wait("/auth/refresh"); app.unlink("linked"); release()
        _ = try? await refresh.value
        try check(app.accts["linked"] == nil, "unlinked refresh resurrected account")
        // Sheet cancellation and unlink both invalidate pending linked login attempts.
        for cancel in [true, false] {
            hold("/login")
            let linking = Task { try await app.login(b, "late-link", "fixture", main: false) }
            try await wait("/login")
            if cancel { linking.cancel() } else { app.unlink("late-link") }
            release(); _ = try? await linking.value
            try check(app.accts["late-link"] == nil, "dismissed linked login committed")
        }
        // A stale network failure must not mark the replacement session offline.
        hold("/api/failure")
        let failing = Task { try await app.api("GET", "/api/failure") }
        try await wait("/api/failure")
        IsolationProtocol.state.withLock { $0.hold = nil }
        try await app.login(a, "same", "fixture", main: true)
        release(); _ = try? await failing.value
        try check(!app.offline, "stale failure marked replacement offline")
        try await app.login(b, "new", "fixture", main: true)
        // Actual AVFoundation resource loading uses immutable URL/token pairs and byte ranges.
        let loader = MediaLoader(url: URL(string: b + "/audio.wav")!, token: try await app.token(), epoch: app.mediaEpoch)
        let duration = try await loader.asset.load(.duration)
        try check(duration.seconds > 0, "native stream not readable")
        loader.cancel()
        hold("/api/items/cover/cover")
        let cover = Task { await Covers.get("cover") }
        try await wait("/api/items/cover/cover")
        IsolationProtocol.state.withLock { $0.hold = nil }
        try await app.login(a, "same", "fixture", main: true)
        release(); _ = await cover.value
        try check(Covers.mem("cover") == nil && !app.offline, "stale cover changed new session")
        // Every real URLSession route carries only its own host's synthetic credential.
        let requests = IsolationProtocol.state.withLock { $0.requests }
        try check(requests.contains { $0.url?.path == "/auth/refresh" && $0.url?.host == "isolation-a.invalid" }, "missing A refresh route")
        for r in requests {
            let host = r.url!.host!
            for key in ["Authorization", "x-refresh-token"] {
                if let value = r.value(forHTTPHeaderField: key) {
                    try check(value.contains(host), "cross-host credential: " + key)
                }
            }
        }
        try check(!requests.contains { $0.url?.path == "/api/linked" }, "unlinked API sent")
        // All credential-bearing redirect policies reject even a same-origin redirect.
        var redirected = true
        let request = URLRequest(url: URL(string: b + "/redirect")!)
        let response = HTTPURLResponse(url: URL(string: a)!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        NoRedirects.shared.urlSession(app.network, task: app.network.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected = $0 != nil }
        try check(!redirected, "API redirect allowed")
        Downloader.shared.urlSession(app.network, task: app.network.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected = $0 != nil }
        try check(!redirected, "download redirect allowed")
        try check(Downloader.reauth(Data("invalid".utf8), "fixture", expected: URL(string: a)!) == nil, "unsafe resume accepted")
        app.logout()
    }
}

final class IsolationProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var requests: [URLRequest] = [], pending: [IsolationProtocol] = []
        var hold: String?
        var failLogin = false, refresh401 = false
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    override class func canInit(with request: URLRequest) -> Bool { ["isolation-a.invalid", "isolation-b.invalid"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let held = Self.state.withLock { s in
            s.requests.append(request)
            if s.hold == request.url?.path { s.pending.append(self); return true }
            return false
        }
        if !held { respond() }
    }
    static func release() {
        let pending = state.withLock { s in let p = s.pending; s.pending = []; s.hold = nil; return p }
        pending.forEach { $0.respond() }
    }
    func respond() {
        if stopped.withLock({ $0 }) { return }
        if request.url?.path == "/api/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let flags = Self.state.withLock { ($0.failLogin, $0.refresh401) }
        let path = request.url!.path, host = request.url!.host!
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096); var out = Data()
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; out.append(contentsOf: bytes.prefix(n)) }
            data = out
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let username = body?["username"] as? String ?? request.value(forHTTPHeaderField: "x-refresh-token")?.split(separator: "|").last.map(String.init) ?? "same"
        if path == "/audio.wav" {
            let audio = RetainedProtocol.audio
            let bounds = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-1").dropFirst(6).split(separator: "-")
            let start = Int(bounds[0]) ?? 0, end = min(audio.count - 1, Int(bounds.last!) ?? 1)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Type": "audio/wav", "Content-Range": "bytes \(start)-\(end)/\(audio.count)", "Content-Length": "\(end - start + 1)"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: audio.subdata(in: start..<(end + 1)))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let login = path == "/login" || path == "/auth/refresh"
        let json: [String: Any] = login ? ["user": ["username": username, "accessToken": host + "|" + username, "refreshToken": host + "|" + username]] : ["mediaProgress": []]
        let code = (path == "/login" && flags.0) || (path == "/auth/refresh" && flags.1) ? 401 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
#endif
