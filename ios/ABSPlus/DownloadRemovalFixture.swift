#if DEBUG
import SwiftUI

/// Synthetic files in a disposable simulator; exercises production removal, delegates and persisted queue.
struct DownloadRemovalFixture: View {
    @State private var result = "Running"
    private static func episode(_ id: String, item: String = "removal-podcast") -> Now {
        Now(item: item, ep: id, title: "Episode " + id, author: "Fixture", tracks: [
            Track(ino: id, ext: ".mp3", size: 7, duration: 60, start: 0)])
    }
    var body: some View { Text(result).task { await run() } }

    @MainActor private func run() async {
        let fm = FileManager.default, downloader = Downloader.shared
        let a = Self.episode("a"), b = Self.episode("b"), c = Self.episode("c"), d = Self.episode("d")
        let other = Self.episode("other", item: "removal-other")
        func file(_ n: Now) -> URL { app.file(n.item, n.tracks[0]) }
        func rel(_ n: Now) -> String { app.rel(n.item, n.tracks[0]) }
        func put(_ n: Now, _ bytes: String) {
            try! fm.createDirectory(at: file(n).deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(bytes.utf8).write(to: file(n))
        }
        func content(_ n: Now) -> String { String(data: try! Data(contentsOf: file(n)), encoding: .utf8)! }
        func card(_ n: Now) -> Card { Card(id: n.item, title: n.title, sub: "", ep: n.ep) }
        func absent(_ n: Now) {
            assert(!fm.fileExists(atPath: file(n).path))
            assert(!fm.fileExists(atPath: app.resumeFile(rel(n)).path))
            assert(!app.queued(n) && app.transfers[rel(n)] == nil && !app.inflight.contains(rel(n)))
            assert(app.dlRetry[rel(n)] == nil && app.got[rel(n)] == nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--removal-relaunch") {
            app.offline = true
            absent(a); absent(c)
            assert(content(b) == "saved-b" && content(d) == "par" && content(other) == "outside")
            assert(app.downloaded(card(b)) && !app.downloaded(card(a)) && !app.downloaded(card(c)))
            assert(app.url(b.item, b.tracks[0]) == file(b), "Offline playback must still resolve to saved B")
            assert(app.queued(d) && app.dlq.count == 1 && app.dlRetry[rel(d)]?.attempts == 2)
            assert(try! Data(contentsOf: app.resumeFile(rel(d))) == Data("resume-d".utf8))
            await downloader.restore() // fake transfer is gone; durable retry/partial must survive reconciliation
            await app.resumeQueue() // future deadline prevents requests, even offline
            assert(app.queued(d) && app.inflight.isEmpty && content(d) == "par")
            app.removeAll(a.item)
            for n in [a, b, c, d] { absent(n) }
            assert(!fm.fileExists(atPath: file(a).deletingLastPathComponent().path))
            assert(content(other) == "outside")
            // The last selected file still cleans up its now-empty folder.
            app.remove(other)
            assert(!fm.fileExists(atPath: file(other).deletingLastPathComponent().path))
            let restored = Abs()
            assert(restored.dlq.isEmpty && restored.dlRetry.isEmpty && restored.transfers.isEmpty)
            result = "Removal relaunch passed"
            return
        }

        app.logout()
        app.d.set("http://removal-fixture.invalid", forKey: "server")
        app.me = "fixture"; app.accts = ["fixture": Tok(a: "fixture", r: "")]
        app.offline = true
        app.removeAll(a.item); app.removeAll(other.item)
        let episodes: [[String: Any]] = [a, b, c, d].map { n in
            ["id": n.ep!, "title": n.title, "audioFile": ["ino": n.tracks[0].ino,
                "duration": 60, "metadata": ["ext": ".mp3", "size": 7]]]
        }
        let item: [String: Any] = ["id": a.item, "mediaType": "podcast",
            "media": ["metadata": ["title": "Fixture"], "episodes": episodes]]
        let path = "/api/items/\(a.item)?expanded=1"
        let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        try! JSONSerialization.data(withJSONObject: item).write(to: app.cacheDir.appending(path: name))
        put(a, "saved-a"); put(b, "saved-b"); put(c, "par"); put(d, "par"); put(other, "outside")
        app.dlq = [c, d]
        let deadline = Date().addingTimeInterval(3600)
        for n in [c, d] {
            try! Data("resume-\(n.ep!)".utf8).write(to: app.resumeFile(rel(n)))
            app.dlRetry[rel(n)] = DownloadRetry(attempts: 2, next: deadline)
            app.got[rel(n)] = 3
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func task(_ n: Now) -> RemovalTask {
            let t = RemovalTask()
            t.reply = HTTPURLResponse(url: URL(string: "http://removal-fixture.invalid/f")!, statusCode: 200, httpVersion: nil, headerFields: nil)
            downloader.bind(t, rel(n)); return t
        }
        let cancelled = task(c), sibling = task(d)
        app.dlChanged()
        assert(app.downloaded(card(a)) && app.downloaded(card(b)))
        app.remove(a)
        absent(a)
        assert(!app.downloaded(card(a)) && app.downloaded(card(b)))
        assert(content(b) == "saved-b" && content(c) == "par" && content(d) == "par")
        assert(app.queued(c) && app.queued(d) && app.transfers[rel(d)] == sibling.taskDescription)
        app.remove(c)
        absent(c)
        assert(content(b) == "saved-b" && content(d) == "par")
        assert(app.inflight.contains(rel(d)) && app.transfers[rel(d)] == sibling.taskDescription)
        assert(app.got[rel(d)] == 3 && app.dlRetry[rel(d)]?.next == deadline)
        assert(try! Data(contentsOf: app.resumeFile(rel(d))) == Data("resume-d".utf8))
        // A cancelled callback must not resurrect C or affect the still-active sibling.
        let late = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try! Data("late-c!".utf8).write(to: late)
        downloader.urlSession(session, downloadTask: cancelled, didFinishDownloadingTo: late)
        downloader.urlSession(session, task: cancelled, didCompleteWithError: URLError(.cancelled))
        try? fm.removeItem(at: late)
        absent(c)
        assert(content(b) == "saved-b" && content(d) == "par" && app.inflight.contains(rel(d)))
        let restored = Abs()
        assert(restored.dlq.map(\.key) == [d.key] && restored.transfers[rel(d)] == sibling.taskDescription)
        assert(restored.downloaded(card(b)) && restored.url(b.item, b.tracks[0]).isFileURL)
        result = "Removal seed passed"
    }
}

private final class RemovalTask: URLSessionDownloadTask, @unchecked Sendable {
    var reply: URLResponse?
    override var response: URLResponse? { reply }
}
#endif
