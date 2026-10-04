#if DEBUG
import SwiftUI
import os

/// Only a reserved .invalid host is intercepted. No credentials or real mutations.
struct LoadingFixture: View {
    private static var configured = false
    @State private var positionCount = 0
    @State private var favoriteCount = -1
    init() {
        guard !Self.configured else { return }
        Self.configured = true
        URLProtocol.registerClass(LoadingProtocol.self)
        let defaults = UserDefaults.standard
        defaults.set("http://abs-loading-fixture.invalid", forKey: "server")
        defaults.set("fixture", forKey: "lib")
        defaults.removeObject(forKey: "now")
        app.me = "loading-fixture"
        app.accts = ["loading-fixture": Tok(a: "fixture", r: "")]
        app.fav = []; app.favq = [:]; app.hist = []; app.dlq = []; app.shares = [:]
        try? FileManager.default.removeItem(at: app.cacheDir)
        try? FileManager.default.createDirectory(at: app.cacheDir, withIntermediateDirectories: true)
        for id in ["first", "other", "podcast"] {
            try? FileManager.default.removeItem(at: dlDir.appending(path: "\(id)/fixture-audio.wav"))
        }
        if ProcessInfo.processInfo.arguments.contains("--populated-favorites") {
            app.fav = [Card(id: "favorite", title: "Known favorite", sub: "Fixture author")]
        }
        if ProcessInfo.processInfo.arguments.contains("--playback") {
            // Silent local PCM exercises the real AVQueuePlayer without network media.
            let samples = 8_000 * 120
            var wav = Data()
            func word(_ value: UInt32, bytes: Int = 4) {
                for shift in 0..<bytes { wav.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
            }
            wav.append(Data("RIFF".utf8)); word(UInt32(36 + samples * 2))
            wav.append(Data("WAVEfmt ".utf8)); word(16); word(1, bytes: 2); word(1, bytes: 2)
            word(8_000); word(16_000); word(2, bytes: 2); word(16, bytes: 2)
            wav.append(Data("data".utf8)); word(UInt32(samples * 2))
            wav.append(Data(repeating: 0, count: samples * 2))
            for id in ["first", "other", "podcast"] {
                let folder = dlDir.appending(path: id)
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try! wav.write(to: folder.appending(path: "fixture-audio.wav"))
            }
            app.hist = [Hist(card: Card(id: "other", title: "Recent title", sub: "Fixture author"), at: ms())]
        }
        if ProcessInfo.processInfo.arguments.contains("--cached") {
            let path = "/api/libraries/fixture/items?minified=1&sort=media.metadata.title"
            let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            let data = try! JSONSerialization.data(withJSONObject: ["results": [LoadingProtocol.item("cached", "Cached title")]])
            try! data.write(to: app.cacheDir.appending(path: name))
        }
    }
    var body: some View {
        Group {
        if ProcessInfo.processInfo.arguments.contains("--login") { LoginView() }
        else { RootView() }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
            HStack {
                Button("Release fixture requests") { LoadingProtocol.released.withLock { $0 = true } }
                Button("Hold fixture requests") { LoadingProtocol.released.withLock { $0 = false } }
            }
            if ProcessInfo.processInfo.arguments.contains("--playback") {
                HStack {
                    Button("Release positions") { LoadingProtocol.positionsReleased.withLock { $0 = true } }
                    Button("Hold positions") { LoadingProtocol.positionsReleased.withLock { $0 = false } }
                    Button("Check positions") { positionCount = LoadingProtocol.counts.withLock { counts in counts.filter { $0.key.hasPrefix("/api/me/progress/") }.values.reduce(0, +) } }
                }
                Text("Current: \(player.now?.key ?? "none"); preparing: \(player.preparing ?? "none"); playing: \(player.playing ? "true" : "false")")
                    .accessibilityIdentifier("fixture.playback")
                Text("Position requests: \(positionCount)").accessibilityIdentifier("fixture.positions")
            }
            if ProcessInfo.processInfo.arguments.contains("--populated-favorites") {
                Button("Check favorite requests") { favoriteCount = LoadingProtocol.counts.withLock { $0["/api/items/favorite", default: 0] } }
                Text("Favorite metadata requests: \(favoriteCount)").accessibilityIdentifier("fixture.favorites")
            }
            }.font(.caption2).padding(4).background(.regularMaterial).padding(.top, 45)
        }
    }
}

final class LoadingProtocol: URLProtocol, @unchecked Sendable {
    static let positionsReleased = OSAllocatedUnfairLock(initialState: false)
    static let released = OSAllocatedUnfairLock(initialState: false)
    static let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs-loading-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func item(_ id: String, _ title: String) -> [String: Any] {
        let playback = ProcessInfo.processInfo.arguments.contains("--playback")
        let track: [String: Any] = ["ino": "fixture-audio", "duration": 120, "startOffset": 0,
                                    "metadata": ["ext": ".wav", "size": 1_920_044]]
        var media: [String: Any] = ["metadata": ["title": title, "authorName": "Fixture author"]]
        if playback && id == "podcast" {
            media["episodes"] = [["id": "episode", "title": "Fixture episode", "audioFile": track]]
        } else { media["tracks"] = playback ? [track] : [] }
        return ["id": id, "mediaType": playback && id == "podcast" ? "podcast" : "book", "media": media]
    }
    override func startLoading() {
        let path = request.url!.path
        let count = Self.counts.withLock { counts in counts[path, default: 0] += 1; return counts[path]! }
        let args = ProcessInfo.processInfo.arguments
        let position = path.hasPrefix("/api/me/progress/") && request.httpMethod == "GET"
        let playback = args.contains("--playback")
        let isContent = path.hasSuffix("/items") || path.hasSuffix("/series") || path == "/api/me" || path.contains("/api/items/") && !path.hasSuffix("/cover") || path.contains("items-in-progress") || path == "/login"
        let empty = args.contains("--empty")
        let fail = args.contains("--failure") && count == 1 && isContent
        let offline = args.contains("--offline") && isContent
        let body: [String: Any]
        if position {
            body = ["libraryItemId": path.components(separatedBy: "/")[4], "currentTime": 0, "lastUpdate": 0]
        } else if path == "/api/libraries" {
            body = ["libraries": args.contains("--no-libraries") ? [] : [["id": "fixture", "name": "Fixture Library", "mediaType": "book"], ["id": "other", "name": "Other Library", "mediaType": "book"]]]
        } else if path == "/api/me" {
            body = ["mediaProgress": [], "bookmarks": empty ? [] : [["libraryItemId": "favorite", "title": "♥ Favorite"]]]
        } else if path.hasSuffix("/items") {
            body = ["results": empty ? [] : playback ? [Self.item("first", "Loaded title"), Self.item("other", "Other title"), Self.item("podcast", "Podcast title")] : [Self.item(path.contains("other") ? "other" : "first", path.contains("other") ? "Other title" : "Loaded title")]]
        } else if path.hasSuffix("/series") {
            body = ["results": empty ? [] : [["id": "series", "name": "Loaded series", "books": [Self.item("first", "Loaded title")]]]]
        } else if path.contains("items-in-progress") {
            body = ["libraryItems": empty ? [] : playback ? [Self.item("first", "Loaded title"), Self.item("other", "Other title")] : [Self.item("first", "Loaded title")]]
        } else if path == "/login" {
            body = ["user": ["username": "loading-fixture", "accessToken": "fixture"]]
        } else {
            let id = path.components(separatedBy: "/").last ?? "first"
            body = Self.item(id, playback ? id == "other" ? "Other title" : id == "podcast" ? "Podcast title" : "Loaded title" : "Loaded details")
        }
        DispatchQueue.global().async { [self] in
            // Initial responses wait for the UI test, not a race against XCTest startup.
            let deadline = Date().addingTimeInterval(60)
            while (position && !Self.positionsReleased.withLock({ $0 }) || isContent && !Self.released.withLock({ $0 })) && !stopped.withLock({ $0 }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if isContent || position { Thread.sleep(forTimeInterval: 2.5) }
            guard !stopped.withLock({ $0 }) else { return }
            if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            let code = path.hasSuffix("/cover") ? 404 : fail ? 503 : 200
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
#endif
