#if DEBUG
import SwiftUI

/// Disposable simulator only: real Library/Storage views with synthetic local files.
struct OfflineLibraryFixture: View {
    private static var seeded = false
    init() {
        guard !Self.seeded else { return }; Self.seeded = true
        URLProtocol.registerClass(OfflineHomeProtocol.self)
        app.d.set("http://abs-home-fixture.invalid", forKey: "server")
        app.d.set("", forKey: "lib")
        app.accts["library-fixture"] = Tok(a: "fixture", r: "")
        app.me = "library-fixture"
        app.offline = true
        app.dlq = []
        for id in ["partial", "complete", "zero", "podcast", "podcast-zero", "empty", "missing-zero"] {
            Self.seed(id, podcast: id.hasPrefix("podcast"), empty: id == "empty", size: id == "missing-zero" ? 0 : 7)
        }
        Self.save("partial", "one")
        Self.save("complete", "one"); Self.save("complete", "two")
        Self.save("podcast", "one")
        // Retain unfinished bytes in Storage without advertising playable titles.
        for id in ["zero", "podcast-zero"] { Self.save(id, "one", bytes: "short") }
        for id in ["empty", "missing-zero"] { Self.save(id, "unrelated", bytes: "short") }
        for i in 0..<120 {
            let id = String(format: "anchor-%03d", i)
            Self.seed(id); Self.save(id, "one"); Self.save(id, "two")
        }
        app.dlChanged()
        assert(app.downloaded("complete") && app.downloaded("podcast"))
        for id in ["partial", "zero", "podcast-zero", "empty", "missing-zero"] { assert(!app.downloaded(id)) }
    }
    static func seed(_ id: String, podcast: Bool = false, empty: Bool = false, size: Int = 7) {
        try? FileManager.default.removeItem(at: dlDir.appending(path: id))
        try! FileManager.default.createDirectory(at: dlDir.appending(path: id), withIntermediateDirectories: true)
        let audio: [[String: Any]] = ["one", "two"].map { ["ino": $0, "duration": 60, "metadata": ["ext": ".mp3", "size": size]] }
        var media: [String: Any] = ["metadata": ["title": "Fixture " + id]]
        if podcast { media["episodes"] = zip(["one", "two"], audio).map { ["id": $0.0, "title": $0.0, "audioFile": $0.1] as [String: Any] } }
        else { media["tracks"] = empty ? [] : audio }
        OfflineHomeFixture.cache("/api/items/\(id)?expanded=1", ["id": id, "mediaType": podcast ? "podcast" : "book", "media": media])
    }
    static func save(_ id: String, _ ino: String, bytes: String = "fixture") {
        try! Data(bytes.utf8).write(to: dlDir.appending(path: "\(id)/\(ino).mp3"))
    }
    var body: some View {
        Stack { LibraryView() }
            .safeAreaInset(edge: .top) {
                HStack {
                    Button("Complete partial") { Self.save("partial", "two"); app.dlChanged() }
                    Button("Undo partial") {
                        try? FileManager.default.removeItem(at: dlDir.appending(path: "partial/two.mp3")); app.dlChanged()
                    }
                    Button("Remove episode") {
                        try? FileManager.default.removeItem(at: dlDir.appending(path: "podcast/one.mp3")); app.dlChanged()
                    }
                }.buttonStyle(.bordered).font(.caption)
            }
    }
}
#endif
