#if DEBUG
import SwiftUI

/// Exercises the real series route and detail removal using disposable fixture files.
struct OfflineSeriesFixture: View {
    @State private var seeded = false
    @State private var failure: String?
    private func seed() async throws {
        URLProtocol.registerClass(OfflineSeriesProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineSeriesProtocol.self]
        app.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
        app.logout()
        try await app.login("http://abs-series-fixture.invalid", "series-fixture", "fixture", main: true)
        app.offline = true
        app.dlq = []
        let books: [[String: Any]] = (0..<300).map { i in
            let id = Self.id(i)
            let book: [String: Any] = ["id": id, "mediaType": "book", "media": [
                "metadata": ["title": String(format: "Series title %03d", i), "authorName": "Fixture Author"],
                "tracks": [["ino": "audio", "duration": 60, "metadata": ["ext": ".mp3", "size": 7]]]
            ]]
            Self.cache("/api/items/\(id)?expanded=1", book)
            try? FileManager.default.removeItem(at: app.mediaDir.appending(path: "audio/" + id))
            // Initially unavailable titles prove the route retains its unfiltered roster.
            if i >= 6 { Self.save(i) }
            return book
        }
        Self.cache("/api/libraries", ["libraries": [["id": "series-fixture", "name": "Fixture books", "mediaType": "book"]]])
        Self.cache("/api/libraries/series-fixture/series?limit=1000&sort=name", ["results": [["id": "cached", "name": "Cached series", "books": books]]])
        app.dlChanged()
    }

    private static func id(_ i: Int) -> String { "series-fixture-\(i)" }
    private static func cache(_ path: String, _ json: [String: Any]) {
        let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        try! JSONSerialization.data(withJSONObject: json).write(to: app.cacheDir.appending(path: name))
    }
    private static func save(_ i: Int) {
        let dir = app.mediaDir.appending(path: "audio/" + id(i))
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data("fixture".utf8).write(to: dir.appending(path: "audio.mp3"))
        app.dlChanged()
    }

    var body: some View {
        Group {
            if seeded { fixture } else { Text(failure ?? "Preparing offline Series").task {
                do { try await seed(); seeded = true } catch { failure = error.localizedDescription }
            } }
        }
    }
    private var fixture: some View {
        Stack { SeriesView() }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    HStack {
                        Button("Insert ahead") {
                            // Several authoritative callbacks in one main-thread turn.
                            for i in 0..<6 { Self.save(i) }
                        }
                        Button("Remove ahead") {
                            for i in 0..<6 { app.removeAll(Self.id(i)) }
                        }
                    }
                    HStack {
                        Button("Go online") { app.offline = false }
                        Button("Go offline") { app.offline = true }
                        Button("Notify twice") { app.dlChanged(); app.dlChanged() }
                    }
                }.font(.caption).buttonStyle(.bordered)
            }
    }
}

final class OfflineSeriesProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs-series-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/login" else {
            // The buttons own connectivity. A real refresh error must still expose
            // Retry without a network-error callback overriding the explicit state.
            client?.urlProtocol(self, didFailWithError: Msg(errorDescription: "Fixture refresh unavailable")); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"user":{"id":"series-fixture-id","username":"series-fixture","accessToken":"fixture"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
