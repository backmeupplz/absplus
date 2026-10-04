#if DEBUG
import SwiftUI
import os
import AVFoundation
import Network
import CryptoKit

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
        try await accountIsolation(a)
        try await downloadRedirects()
        // API policy also rejects even a same-origin redirect.
        var redirected = true
        let request = URLRequest(url: URL(string: b + "/redirect")!)
        let response = HTTPURLResponse(url: URL(string: a)!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        NoRedirects.shared.urlSession(app.network, task: app.network.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected = $0 != nil }
        try check(!redirected, "API redirect allowed")
        try check(Downloader.reauth(Data("invalid".utf8), "fixture", expected: URL(string: a)!) == nil, "unsafe resume accepted")
        app.logout()
    }

    @MainActor private func accountIsolation(_ server: String) async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw Msg(errorDescription: message) } }
        let fm = FileManager.default, path = "/api/items/restricted?expanded=1"
        try await app.login(server, "account-a", "fixture", main: true)
        let item = try await app.get(path)
        let track = try JSONDecoder().decode(Item.self, from: item).media.tracks![0].track()
        let original = app.mediaDir, file = app.file("restricted", track)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RetainedProtocol.audio.write(to: file)
        // Both historical layouts remain untouched, but neither can be adopted by B.
        let serverHash = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = [dlDir.appending(path: "servers/" + serverHash + "/audio/restricted/1.wav"), dlDir.appending(path: "restricted/1.wav")]
        let legacyJSON = URL.applicationSupportDirectory.appending(path: "json/" + String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" }))
        let legacyMetadata = dlDir.appending(path: "servers/" + serverHash + "/metadata/" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined())
        for url in [legacyJSON, legacyMetadata] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try item.write(to: url)
        }
        for url in legacy {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RetainedProtocol.audio.write(to: url)
        }
        try await app.login(server, "account-b", "fixture", main: true)
        var rendered = false
        await app.load(path) { (_: Item) in rendered = true }
        try check(!rendered && app.cached(path) == nil && app.toast?.contains("403") == true, "B rendered A metadata despite 403")
        do { _ = try await app.item("restricted"); throw Msg(errorDescription: "B item lookup bypassed 403") }
        catch let e as HttpErr where e.code == 403 {}
        try check(app.downloads().isEmpty && !app.downloaded("restricted") && !app.done("restricted", track) && !app.url("restricted", track).isFileURL, "B resolved A local audio")
        let now = Now(item: "restricted", ep: nil, title: "A private book", author: "", tracks: [track])
        player.start(now, 0, play: false)
        for _ in 0..<40 where player.p.currentItem == nil { try await Task.sleep(for: .milliseconds(25)) }
        guard let asset = player.p.currentItem?.asset as? AVURLAsset else { throw Msg(errorDescription: "B production playback resolution not exercised") }
        try check(!asset.url.isFileURL, "B production player loaded A local file")
        player.clear()
        try check(try Data(contentsOf: file) == RetainedProtocol.audio, "B destroyed A audio")
        try await app.login(server, "account-a", "fixture", main: true)
        try check(app.mediaDir == original && app.downloaded("restricted"), "A relogin lost retained media")
        let audio = try AVAudioPlayer(contentsOf: app.url("restricted", track))
        try check(audio.prepareToPlay() && audio.play(), "A relogin local playback failed"); audio.stop()
        for url in legacy { try check(try Data(contentsOf: url) == RetainedProtocol.audio, "legacy bytes deleted") }
        for url in [legacyJSON, legacyMetadata] { try check(try Data(contentsOf: url) == item, "legacy metadata deleted") }
        // Refresh preserves account scope and login generation; conflicting identity cannot commit.
        let tok = app.accts["account-a"]!
        for id in [nil, "different-id", tok.userID] {
            IsolationProtocol.state.withLock { $0.omitID = id == nil; $0.accountID = id }
            app.accts["account-a"]!.a = "x.eyJleHAiOjB9.x"
            do { _ = try await app.token(); try check(id != "different-id", "conflicting refresh accepted") }
            catch is Expired { try check(id == "different-id", "valid refresh rejected") }
            try check(app.mediaDir == original && app.accts["account-a"]?.mediaID == tok.mediaID && app.accts["account-a"]?.id == tok.id, "refresh changed media identity")
        }
        IsolationProtocol.state.withLock { $0.omitID = true; $0.accountID = nil }
        try await app.login(server, "no-id", "fixture", main: true)
        let fallback = app.mediaDir
        app.d.set(try JSONEncoder().encode(["obsolete": "old-task"]), forKey: "transfers")
        let restarted = Abs()
        try check(restarted.mediaDir == fallback && restarted.transfers.isEmpty && app.d.data(forKey: "transfers") == nil, "restart identity or transfer reset failed")
        app.accts["no-id"]!.a = "x.eyJleHAiOjB9.x"
        _ = try await app.token()
        try check(app.mediaDir == fallback && app.accts["no-id"]?.mediaID == restarted.accts["no-id"]?.mediaID, "fallback refresh changed identity")
        try await app.login(server, "no-id", "fixture", main: true)
        try check(app.mediaDir != fallback, "missing ID reused username identity")
        IsolationProtocol.state.withLock { $0.omitID = false }
        // Upgrade from a token written before mediaID existed: random, persisted, never username-bound.
        app.accts["no-id"]!.mediaID = nil
        let migrated = Abs(), migratedAgain = Abs()
        try check(migrated.mediaDir == migratedAgain.mediaDir && migrated.mediaDir != fallback && migrated.accts["no-id"]?.mediaID?.hasPrefix("login:") == true, "legacy login identity was not persisted")
        try check(migrated.cached(path) == nil && migrated.downloads().isEmpty, "upgrade adopted unscoped cache/media")
    }

    @MainActor private func downloadRedirects() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw Msg(errorDescription: message) } }
        let sink = try LoopbackDownloadServer(), source = try LoopbackDownloadServer()
        defer { source.stop(); sink.stop() }
        let sinkURL = try await sink.start()
        source.redirect = sinkURL.appending(path: "sink")
        let sourceURL = try await source.start()
        try check(Downloader.shared.session.configuration.identifier == nil, "download transport is background")
        for (path, code) in [("redirect", 307), ("success", 200)] {
            let track = Track(ino: path, ext: ".wav", size: Int64(RetainedProtocol.audio.count), duration: 1, start: 0)
            let rel = app.rel("socket-fixture", track), file = app.file("socket-fixture", track)
            try? FileManager.default.removeItem(at: file)
            var request = URLRequest(url: sourceURL.appending(path: path))
            request.setValue("Bearer synthetic-download-only", forHTTPHeaderField: "Authorization")
            // Actual production session and delegate, not a direct redirect callback invocation.
            let task = Downloader.shared.session.downloadTask(with: request)
            Downloader.shared.bind(task, rel); task.resume()
            for _ in 0..<500 {
                if !app.inflight.contains(rel) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(!app.inflight.contains(rel), "socket download timed out")
            try check((task.response as? HTTPURLResponse)?.statusCode == code, "wrong socket response: " + path + " status=" + String((task.response as? HTTPURLResponse)?.statusCode ?? -1) + " error=" + (task.error?.localizedDescription ?? "none") + " requests=" + String(source.requests.withLock { $0.count }))
            if code == 200 { try check(try Data(contentsOf: file) == RetainedProtocol.audio, "successful transport did not commit bytes") }
            else { try check(!FileManager.default.fileExists(atPath: file.path), "redirect committed file") }
        }
        try await Task.sleep(for: .milliseconds(100))
        try check(sink.requests.withLock { $0.isEmpty }, "redirect sink received request/auth")
        let requests = source.requests.withLock { $0 }
        try check(requests.count == 2 && requests.allSatisfy { $0.contains("Bearer synthetic-download-only") }, "source did not receive authenticated requests")
    }
}

final class IsolationProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var requests: [URLRequest] = [], pending: [IsolationProtocol] = []
        var hold: String?
        var failLogin = false, refresh401 = false, omitID = false
        var accountID: String?
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
        let identity = Self.state.withLock { ($0.omitID, $0.accountID) }
        var user = ["username": username, "accessToken": host + "|" + username, "refreshToken": host + "|" + username]
        if !identity.0 { user["id"] = identity.1 ?? "id-" + username }
        let restricted = path == "/api/items/restricted"
        let denied = restricted && request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("|account-b") == true
        let json: [String: Any] = login ? ["user": user] : restricted ? ["id": "restricted", "media": ["metadata": ["title": "A private book"], "tracks": [["ino": "1", "duration": 1, "metadata": ["ext": ".wav", "size": RetainedProtocol.audio.count]]]]] : ["mediaProgress": []]
        let code = (path == "/login" && flags.0) || (path == "/auth/refresh" && flags.1) ? 401 : denied ? 403 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
/// Real TCP/HTTP fixture; production URLSession controls redirect handling.
private final class LoopbackDownloadServer: @unchecked Sendable {
    let requests = OSAllocatedUnfairLock(initialState: [String]())
    var redirect: URL?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "absplus.isolation.http")
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())
    private let ready = OSAllocatedUnfairLock(initialState: false)
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: queue)
            receive(connection, Data())
        }
        // port can be populated before the socket is accepting; wait for .ready, not port alone.
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state { ready.withLock { $0 = true } }
        }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if ready.withLock({ $0 }), let port = listener.port { return URL(string: "http://127.0.0.1:" + String(port.rawValue))! }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Msg(errorDescription: "Loopback HTTP listener did not start")
    }
    func stop() {
        listener.cancel()
        connections.withLock { $0.forEach { $0.cancel() }; $0 = [] }
    }
    private func receive(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] data, _, complete, error in
            var bytes = prefix; bytes.append(data ?? Data())
            guard bytes.count <= 32768 else { connection.cancel(); return }
            let request = String(decoding: bytes, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if !complete && error == nil { receive(connection, bytes) } else { connection.cancel() }
                return
            }
            requests.withLock { $0.append(request) }
            let redirected = request.hasPrefix("GET /redirect ") && redirect != nil
            let body = redirected ? Data() : RetainedProtocol.audio
            let status = redirected ? "307 Temporary Redirect" : "200 OK"
            let location = redirected ? "Location: " + redirect!.absoluteString + "\r\n" : ""
            var response = Data(("HTTP/1.1 " + status + "\r\n" + location + "Content-Type: audio/wav\r\nContent-Length: " + String(body.count) + "\r\nConnection: close\r\n\r\n").utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
