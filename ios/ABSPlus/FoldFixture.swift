#if DEBUG
import SwiftUI
import UIKit
import os

/// iPhone Duo fold check (#213): the real app signed in to a stub server, plus a window above everything (sheets
/// included) whose button flips the scene's horizontal size class live, the way folding or unfolding the phone does.
struct FoldFixture: View {
    @State private var ready = false

    var body: some View {
        Group {
            if ready { RootView() } else { ProgressView() }
        }
        .task {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FoldProtocol.self]
            app.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
            player.clear()
            app.logout()
            do { try await app.login(FoldProtocol.server, "fold", "fixture", main: true) }
            catch { app.toast = "Fold fixture login failed: " + error.localizedDescription }
            FoldSwitch.install()
            ready = true
        }
    }
}

@MainActor enum FoldSwitch {
    private static var window: UIWindow?

    static func install() {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        // A thin window of its own on the leading edge, where it covers none of the app's controls. (The status bar
        // would be tidier, but taps there go to the system.)
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: scene.coordinateSpace.bounds.height * 0.25, width: 16, height: 64)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: FoldButton())
        host.view.backgroundColor = .clear
        w.rootViewController = host
        window = w // before it shows, so the button's first render can find the app's window
        w.isHidden = false
    }

    static func flip() {
        guard let scene = window?.windowScene else { return }
        // Overriding the scene's traits does not reach its windows' view controllers; overriding each root view
        // controller does, and they pass it on to everything they present.
        let app = scene.windows.first { $0 !== window }?.rootViewController
        let next: UIUserInterfaceSizeClass = app?.traitCollection.horizontalSizeClass == .regular ? .compact : .regular
        for w in scene.windows { w.rootViewController?.traitOverrides.horizontalSizeClass = next }
    }

    /// What covers the app's window (the iPhone Duo's status pill and the camera in it) in screen points, as
    /// "x y width height" joined by ";", for the UI test to check that no control sits under it. Empty before iOS 27.1
    /// and on screens with nothing over them.
    static func occluded() -> String {
        guard #available(iOS 27.1, *),
              let view = window?.windowScene?.windows.first(where: { $0 !== window })?.rootViewController?.view else { return "" }
        return view.reservedRegions(kind: .occlusion).map { r in
            let f = view.convert(r.frame, to: nil)
            return [f.minX, f.minY, f.width, f.height].map { String(format: "%g", $0) }.joined(separator: " ")
        }.joined(separator: ";")
    }
}

private struct FoldButton: View {
    @Environment(\.horizontalSizeClass) private var size
    var body: some View {
        Button { FoldSwitch.flip() } label: {
            Capsule().fill(.tint.opacity(0.6)).padding(.vertical, 4).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
        }
        .accessibilityIdentifier("fold.toggle")
        .accessibilityLabel(FoldSwitch.occluded())
        .accessibilityValue(size == .regular ? "regular" : "compact")
        .ignoresSafeArea()
    }
}

/// A library of public-domain titles, each with one 2-minute silent WAV that streams like a real file.
final class FoldProtocol: URLProtocol, @unchecked Sendable {
    static let server = "http://fold.invalid"
    static let books: [(String, String)] = [
        ("Pride and Prejudice", "Jane Austen"), ("Moby-Dick", "Herman Melville"), ("Frankenstein", "Mary Shelley"),
        ("Dracula", "Bram Stoker"), ("The Time Machine", "H. G. Wells"), ("Treasure Island", "Robert Louis Stevenson"),
        ("Little Women", "Louisa May Alcott"), ("Walden", "Henry David Thoreau"), ("Emma", "Jane Austen"),
        ("Middlemarch", "George Eliot"), ("The Odyssey", "Homer"), ("Alice's Adventures in Wonderland", "Lewis Carroll"),
    ]
    static let audio: Data = {
        let samples = 8000 * 120
        var d = Data()
        func text(_ s: String) { d.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples * 2)); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        text("data"); u32(UInt32(samples * 2)); d.append(Data(count: samples * 2)); return d
    }()
    private static let covers = OSAllocatedUnfairLock(initialState: [String: Data]())

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fold.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func item(_ i: Int, expanded: Bool) -> [String: Any] {
        let (title, author) = books[i]
        var metadata: [String: Any] = ["title": title, "authorName": author]
        if expanded {
            metadata["description"] = "\(title) by \(author). " + String(repeating: "A public-domain classic, read aloud for this layout check. ", count: 8)
        }
        return ["id": "b\(i)", "mediaType": "book", "media": [
            "metadata": metadata,
            "tracks": [["ino": "1", "metadata": ["ext": ".wav", "size": audio.count], "duration": 120, "startOffset": 0]],
        ]]
    }

    private static func cover(_ id: String) -> Data {
        covers.withLock { cache in
            if let data = cache[id] { return data }
            let hue = CGFloat(id.unicodeScalars.reduce(0) { $0 + Int($1.value) * 37 } % 360) / 360
            let data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).pngData { c in
                UIColor(hue: hue, saturation: 0.45, brightness: 0.75, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            }
            cache[id] = data
            return data
        }
    }

    override func startLoading() {
        let url = request.url!, path = url.path
        if path.contains("/file/") {
            let audio = Self.audio
            let bounds = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-1").dropFirst(6).split(separator: "-")
            let start = min(audio.count - 1, Int(bounds[0]) ?? 0), end = min(audio.count - 1, Int(bounds.last!) ?? 1)
            reply(206, audio.subdata(in: start..<(end + 1)), ["Content-Type": "audio/wav", "Content-Range": "bytes \(start)-\(end)/\(audio.count)"])
            return
        }
        if path.hasSuffix("/cover") { reply(200, Self.cover(url.pathComponents.dropLast().last ?? ""), ["Content-Type": "image/png"]); return }
        let all = Self.books.indices.map { Self.item($0, expanded: false) }
        let body: Any?
        switch path {
        case "/login", "/auth/refresh": body = ["user": ["id": "fold-fixture-id", "username": "fold", "accessToken": "fold", "refreshToken": "fold"]]
        case "/ping": body = ["success": true]
        case "/api/me": body = ["mediaProgress": [], "bookmarks": []]
        case "/api/me/items-in-progress": body = ["libraryItems": Array(all.prefix(4))]
        case "/api/libraries": body = ["libraries": [["id": "books", "name": "Audiobooks", "mediaType": "book", "settings": ["coverAspectRatio": 1]]]]
        case "/api/libraries/books/items": body = ["results": all]
        case "/api/libraries/books/series": body = ["results": [["id": "s1", "name": "Classics", "books": all]]]
        default:
            if path.hasPrefix("/api/items/"), let i = Int(path.dropFirst("/api/items/b".count)), Self.books.indices.contains(i) {
                body = Self.item(i, expanded: true)
            } else if request.httpMethod != "GET" {
                body = [String: Any]() // progress and session writes
            } else { body = nil }
        }
        if let body { reply(200, try! JSONSerialization.data(withJSONObject: body), ["Content-Type": "application/json"]) }
        else { reply(404, Data(), [:]) }
    }

    private func reply(_ code: Int, _ data: Data, _ headers: [String: String]) {
        var headers = headers
        headers["Content-Length"] = "\(data.count)"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
