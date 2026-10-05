#if DEBUG
import SwiftUI
import AVFoundation

/// Only launched on a disposable simulator. Uses the real downloaded-file queue and FullPlayer.
struct BookSkipFixture: View {
    @State private var prepared = false
    @State private var snapshot = "preparing"
    @State private var remoteStatus = "none"

    var body: some View {
        VStack(spacing: 0) {
            FullPlayer()
            HStack {
                ForEach([10, 60, 95, 110, 140], id: \.self) { t in
                    Button("At \(t)") { player.seek(Double(t)) }
                }
            }.font(.caption)
            HStack {
                Button("Remote back") { remoteStatus = String(player.remoteSkipBackward().rawValue) }
                Button("Remote forward") { remoteStatus = String(player.remoteSkipForward().rawValue) }
            }.font(.caption)
            Text(snapshot).font(.system(size: 9, design: .monospaced))
                .accessibilityIdentifier("skip-state")
        }
        .task {
            guard !prepared else { return }
            prepared = true
            do { try await seed() } catch { snapshot = "ERROR: \(error)"; return }
            while !Task.isCancelled {
                snapshot = state()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func seed() async throws {
        // Authenticate the synthetic server through production scope selection.
        URLProtocol.registerClass(BookSkipProtocol.self)
        app.logout()
        try await app.login("http://book-skip-fixture.invalid", "fixture", "fixture", main: true)
        app.offline = true
        let id = "book-skip-fixture"
        // Seed artwork on disk so FullPlayer/start never ask a server for a cover.
        let covers = URL.cachesDirectory.appending(path: "covers")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try image.pngData()!.write(to: covers.appending(path: id))
        var tracks: [Track] = []
        for (i, seconds) in [100, 50].enumerated() {
            var track = Track(ino: String(i), ext: ".wav", size: 0, duration: Double(seconds), start: i == 0 ? 0 : 100)
            let url = app.file(id, track)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeAudio(url, seconds: seconds)
            track.size = app.size(url)
            tracks.append(track)
        }
        player.setSpeed(1.5)
        player.start(Now(item: id, ep: nil, title: "Skip parity: 100 + 50 seconds", author: "Local synthetic audio", tracks: tracks), 110, play: false, generation: app.playbackGeneration)
    }

    private func writeAudio(_ url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<8_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 220 / 8_000)) * 0.01 }
        for _ in 0..<seconds { try file.write(from: buffer) }
    }

    private func state() -> String {
        let item = player.p.currentItem
        let url = (item?.asset as? AVURLAsset)?.url
        let track = url?.deletingPathExtension().lastPathComponent ?? "none"
        let offset = player.p.currentTime().seconds
        let global = offset + (track == "1" ? 100 : 0)
        return String(format: "track=%@;offset=%.3f;actual=%.3f;pos=%.3f;rate=%.2f;speed=%.2f;default=%.2f;paused=%@;ready=%@;local=%@;remote=%@",
                      track, offset, global, player.pos, player.p.rate, player.speed, player.p.defaultRate,
                      player.p.timeControlStatus == .paused && !player.playing ? "yes" : "no",
                      item?.status == .readyToPlay ? "yes" : "no", url?.isFileURL == true ? "yes" : "no", remoteStatus)
    }
}

private final class BookSkipProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "book-skip-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard ["/login", "/auth/refresh"].contains(request.url?.path ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = Data(#"{"user":{"username":"fixture","accessToken":"fixture"}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
