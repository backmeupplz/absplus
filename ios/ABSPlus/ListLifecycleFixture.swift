#if DEBUG
import SwiftUI
import os

/// Local-only UI regression fixture: exercises LibraryView's real navigation/task
/// lifecycle without signing in, starting playback or contacting a user's server.
struct ListLifecycleFixture: View {
    init() {
        ListFixtureProtocol.revision.withLock { $0 = 0 }
        URLProtocol.registerClass(ListFixtureProtocol.self)
        UserDefaults.standard.set("http://abs-list-fixture.invalid", forKey: "server")
        UserDefaults.standard.set("fixture", forKey: "lib")
        app.accts["list-fixture"] = Tok(a: "fixture", r: "")
        app.me = "list-fixture"
        // Remove only this fixture's cache, so each run starts with asynchronous data.
        for id in ["fixture", "other"] {
            let path = "/api/libraries/\(id)/items?minified=1&sort=media.metadata.title"
            let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            try? FileManager.default.removeItem(at: app.cacheDir.appending(path: name))
        }
    }
    var body: some View { Stack { LibraryView() } }
}

final class ListFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let revision = OSAllocatedUnfairLock(initialState: 0)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs-list-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.hasPrefix("/api/items/"), !path.hasSuffix("/cover") {
            Self.revision.withLock { $0 += 1 }
            // Cache eviction while reading details must not collapse the retained list.
            let list = "/api/libraries/fixture/items?minified=1&sort=media.metadata.title"
            let name = String(list.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "json/" + name))
        }
        let body: [String: Any]
        if path == "/api/libraries" {
            body = ["libraries": ["fixture", "other"].map { ["id": $0, "name": $0 == "fixture" ? "Fixture Library" : "Other Library", "mediaType": "book"] }]
        } else if path.hasSuffix("/items") {
            let prefix = path.contains("/other/") ? "Other" : "Title"
            let ids: [Int]
            switch prefix == "Other" ? 0 : Self.revision.withLock({ $0 % 4 }) {
            case 1: ids = Array(30..<500) // delete titles ahead of the viewport
            case 2: ids = Array(-30..<500) // insert titles ahead of the viewport
            case 3: ids = Array(30..<500) + Array(0..<30) // reorder existing identities
            default: ids = Array(0..<500)
            }
            body = ["results": ids.map { ["id": "\(prefix)-\($0)", "mediaType": "book", "media": ["metadata": ["title": String(format: "\(prefix) %03d", $0), "authorName": "Fixture Author"]]] }]
        } else if path == "/api/me" {
            body = ["mediaProgress": []]
        } else if path.hasSuffix("/cover") {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        } else {
            body = ["id": path.components(separatedBy: "/").last ?? "", "mediaType": "book", "media": ["metadata": ["title": "Fixture details", "authorName": "Fixture Author"], "tracks": []]]
        }
        // Delay list responses, including the reload triggered by popping details.
        if path.hasSuffix("/items") { Thread.sleep(forTimeInterval: 0.4) }
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
