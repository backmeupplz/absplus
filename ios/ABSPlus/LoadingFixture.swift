#if DEBUG
import SwiftUI
import os

/// Only a reserved .invalid host is intercepted. No credentials or real mutations.
struct LoadingFixture: View {
    private static var configured = false
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
            HStack {
                Button("Release fixture requests") { LoadingProtocol.released.withLock { $0 = true } }
                Button("Hold fixture requests") { LoadingProtocol.released.withLock { $0 = false } }
            }.font(.caption2).padding(4).background(.regularMaterial).padding(.top, 45)
        }
    }
}

final class LoadingProtocol: URLProtocol, @unchecked Sendable {
    static let released = OSAllocatedUnfairLock(initialState: false)
    static let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs-loading-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func item(_ id: String, _ title: String) -> [String: Any] {
        ["id": id, "mediaType": "book", "media": ["metadata": ["title": title, "authorName": "Fixture author"], "tracks": []]]
    }
    override func startLoading() {
        let path = request.url!.path
        let count = Self.counts.withLock { counts in counts[path, default: 0] += 1; return counts[path]! }
        let args = ProcessInfo.processInfo.arguments
        let isContent = path.hasSuffix("/items") || path.hasSuffix("/series") || path == "/api/me" || path.contains("/api/items/") && !path.hasSuffix("/cover") || path.contains("items-in-progress") || path == "/login"
        let empty = args.contains("--empty")
        let fail = args.contains("--failure") && count == 1 && isContent
        let offline = args.contains("--offline") && isContent
        let body: [String: Any]
        if path == "/api/libraries" {
            body = ["libraries": args.contains("--no-libraries") ? [] : [["id": "fixture", "name": "Fixture Library", "mediaType": "book"], ["id": "other", "name": "Other Library", "mediaType": "book"]]]
        } else if path == "/api/me" {
            body = ["mediaProgress": [], "bookmarks": empty ? [] : [["libraryItemId": "favorite", "title": "♥ Favorite"]]]
        } else if path.hasSuffix("/items") {
            body = ["results": empty ? [] : [Self.item(path.contains("other") ? "other" : "first", path.contains("other") ? "Other title" : "Loaded title")]]
        } else if path.hasSuffix("/series") {
            body = ["results": empty ? [] : [["id": "series", "name": "Loaded series", "books": [Self.item("first", "Loaded title")]]]]
        } else if path.contains("items-in-progress") {
            body = ["libraryItems": empty ? [] : [Self.item("first", "Loaded title")]]
        } else if path == "/login" {
            body = ["user": ["username": "loading-fixture", "accessToken": "fixture"]]
        } else {
            body = Self.item(path.components(separatedBy: "/").last ?? "first", "Loaded details")
        }
        DispatchQueue.global().async { [self] in
            // Initial responses wait for the UI test, not a race against XCTest startup.
            let deadline = Date().addingTimeInterval(60)
            while isContent && !Self.released.withLock({ $0 }) && !stopped.withLock({ $0 }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if isContent { Thread.sleep(forTimeInterval: 2.5) }
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
