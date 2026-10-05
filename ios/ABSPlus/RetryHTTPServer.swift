#if DEBUG
import Foundation
import Network

/// Loopback-only server for the download retry fixture. All callbacks run on main.
final class RetryHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port = 0
    private(set) var counts: [String: Int] = [:]
    private(set) var firstAttempt = Date.distantPast
    private(set) var secondAttempt = Date.distantPast
    private(set) var retryTransfer: String?
    private(set) var retryState: DownloadRetry?
    var refreshCode = 200
    var holdRefresh = false
    var holdFiles = false
    private var held: [(NWConnection, String)] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = Int(self?.listener.port?.rawValue ?? 0) }
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let self, let data else { c.cancel(); return }
                let request = String(decoding: data, as: UTF8.self)
                if request.hasPrefix("POST /auth/refresh ") {
                    self.counts["refresh", default: 0] += 1
                    let body = self.refreshCode == 200 ? "{\"user\":{\"username\":\"fixture\",\"accessToken\":\"fixture\",\"refreshToken\":\"refresh-fixture\"}}" : ""
                    let reply = "HTTP/1.1 \(self.refreshCode) Fixture\r\nRetry-After: 120\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    if self.holdRefresh { self.held.append((c, reply)) } else { self.send(c, reply) }
                    return
                }
                let file = request.contains("/file/one/") ? "one" : "two"
                self.counts[file, default: 0] += 1
                let fail = file == "two" && self.counts[file] == 1
                if file == "two" {
                    if fail { self.firstAttempt = Date() } else {
                        self.secondAttempt = Date()
                        MainActor.assumeIsolated {
                            let transfer = app.transfers.first { $0.key.hasSuffix("/two.mp3") }
                            self.retryTransfer = transfer?.value
                            self.retryState = transfer.flatMap { app.dlRetry[$0.key] }
                        }
                    }
                }
                let reply = fail ? "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" :
                    "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture"
                if self.holdFiles { self.held.append((c, reply)) } else { self.send(c, reply) }
            }
        }
        listener.start(queue: .main)
    }
    @MainActor func ready() async {
        for _ in 0..<100 where port == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        assert(port != 0)
    }
    private func send(_ c: NWConnection, _ reply: String) {
        c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
    func release() {
        let pending = held; held = []
        pending.forEach { send($0.0, $0.1) }
    }
    @MainActor func waitFor(_ key: String, count: Int = 1) async {
        for _ in 0..<200 where counts[key, default: 0] < count { try? await Task.sleep(for: .milliseconds(25)) }
        assert(counts[key, default: 0] >= count, "Expected request did not reach fixture")
    }
    func stop() { held.forEach { $0.0.cancel() }; held = []; listener.cancel() }
}
#endif
