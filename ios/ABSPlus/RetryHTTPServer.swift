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
                let file = request.contains("/file/one/") ? "one" : "two"
                self.counts[file, default: 0] += 1
                let fail = file == "two" && self.counts[file] == 1
                if file == "two" {
                    if fail { self.firstAttempt = Date() } else { self.secondAttempt = Date() }
                }
                let reply = fail ? "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" :
                    "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .main)
    }
    @MainActor func ready() async {
        for _ in 0..<100 where port == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        assert(port != 0)
    }
    func stop() { listener.cancel() }
}
#endif
