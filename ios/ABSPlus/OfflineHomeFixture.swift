#if DEBUG
import SwiftUI

/// Disposable-simulator fixture. Synthetic login only; no playback or user server is used.
struct OfflineHomeFixture: View {
    @State private var seeded = false
    @State private var failure: String?
    private func seed() async throws {
        URLProtocol.registerClass(OfflineHomeProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineHomeProtocol.self]
        app.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
        app.logout()
        try await app.login("http://abs-home-fixture.invalid", "home-fixture", "fixture", main: true)
        app.offline = true
        app.dlq = []
        for id in ["home-podcast", "home-book"] {
            try? FileManager.default.removeItem(at: app.mediaDir.appending(path: "audio/" + id))
            try! FileManager.default.createDirectory(at: app.mediaDir.appending(path: "audio/" + id), withIntermediateDirectories: true)
        }
        let episodes: [[String: Any]] = ["saved", "recent"].map { ["id": $0, "title": "Episode " + $0, "audioFile": Self.audio($0)] } + [["id": "no-audio", "title": "No audio"]]
        let podcast: [String: Any] = ["id": "home-podcast", "mediaType": "podcast", "media": ["metadata": ["title": "Fixture Podcast"], "episodes": episodes]]
        let book: [String: Any] = ["id": "home-book", "mediaType": "book", "media": ["metadata": ["title": "Complete book"], "tracks": [Self.audio("one"), Self.audio("two")]]]
        Self.cache("/api/items/home-podcast?expanded=1", podcast)
        Self.cache("/api/items/home-book?expanded=1", book)
        var recent = podcast
        recent["recentEpisode"] = episodes[1]
        Self.cache("/api/me/items-in-progress?limit=20", ["libraryItems": [recent, book]])
        Self.cache("/api/me", ["mediaProgress": []])
        for path in ["home-podcast/saved.mp3", "home-book/one.mp3", "home-book/two.mp3"] {
            try! Data("fixture".utf8).write(to: app.mediaDir.appending(path: "audio/" + path))
        }
        app.hist = [Hist(card: Self.card("recent"), at: ms()), Hist(card: Self.card("saved"), at: ms()), Hist(card: Card(id: "home-book", title: "Complete book", sub: ""), at: ms())]
        app.dlChanged()
        // Edge cases go through the same production predicate used by Home.
        assert(app.downloaded("home-podcast"))
        assert(app.downloaded(Self.card("saved")))
        assert(!app.downloaded(Self.card("recent")))
        assert(app.downloaded(Card(id: "home-book", title: "", sub: "")))
        let secondTrack = app.mediaDir.appending(path: "audio/home-book/two.mp3")
        try! FileManager.default.removeItem(at: secondTrack)
        app.dlChanged()
        assert(!app.downloaded(Card(id: "home-book", title: "", sub: "")))
        try! Data("fixture".utf8).write(to: secondTrack)
        app.dlChanged()
        assert(!app.downloaded(Self.card("no-audio")))
        assert(!app.downloaded(Self.card("unknown")))
        assert(!app.downloaded(Card(id: "uncached", title: "", sub: "", ep: "saved")))
        try! Data("short".utf8).write(to: Self.recentFile)
        app.dlChanged()
        assert(!app.downloaded(Self.card("recent")))
        try! FileManager.default.removeItem(at: Self.recentFile)
        app.dlChanged()
    }
    static var recentFile: URL { app.mediaDir.appending(path: "audio/home-podcast/recent.mp3") }
    static func card(_ ep: String) -> Card { Card(id: "home-podcast", title: "Episode " + ep, sub: "Fixture Podcast", ep: ep) }
    static func audio(_ id: String) -> [String: Any] { ["ino": id, "duration": 60, "metadata": ["ext": ".mp3", "size": 7]] }
    static func cache(_ path: String, _ json: [String: Any]) {
        let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        try! JSONSerialization.data(withJSONObject: json).write(to: app.cacheDir.appending(path: name))
    }
    var body: some View {
        Group {
            if seeded { fixture } else { Text(failure ?? "Preparing offline Home").task {
                do { try await seed(); seeded = true } catch { failure = error.localizedDescription }
            } }
        }
    }
    private var fixture: some View {
        Stack { HomeView() }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Save recent") {
                        try! Data("fixture".utf8).write(to: Self.recentFile)
                        app.dlChanged()
                    }
                    Button("Remove recent") {
                        try? FileManager.default.removeItem(at: Self.recentFile)
                        app.dlChanged()
                    }
                }.buttonStyle(.bordered)
            }
    }
}

final class OfflineHomeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs-home-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/login" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"user":{"username":"home-fixture","accessToken":"fixture"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
