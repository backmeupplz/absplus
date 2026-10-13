#if DEBUG
import SwiftUI
import AVFoundation

/// Only launched on a disposable simulator. Uses the real downloaded-file queue and FullPlayer.
struct BookSkipFixture: View {
    @State private var prepared = false
    @State private var snapshot = "preparing"
    @State private var remoteStatus = "none"
    @State private var skips = SkipLatch()

    var body: some View {
        VStack(spacing: 0) {
            FullPlayer()
            HStack {
                ForEach([10, 60, 80, 95, 110, 140], id: \.self) { t in
                    Button("At \(t)") { reseed(Double(t)) }
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
                skips.observe()
                snapshot = state()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    @MainActor private func seed() async throws {
        // Authenticate through production scope binding using only a synthetic transport.
        app.logout()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BookSkipLoginProtocol.self]
        app.network = URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
        try await app.login("https://book-skip-fixture.invalid", "skip-fixture", "fixture", main: true)
        app.offline = true
        let id = "book-skip-fixture"
        let dir = app.file(id, Track(ino: "0", ext: ".wav", size: 0, duration: 100, start: 0)).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seed artwork on disk so FullPlayer/start never ask a server for a cover.
        let covers = URL.cachesDirectory.appending(path: "account-covers/" + app.mediaScope)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try image.pngData()!.write(to: covers.appending(path: id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        var tracks: [Track] = []
        for (i, seconds) in [100, 50].enumerated() {
            let url = dir.appending(path: "\(i).wav")
            try writeAudio(url, seconds: seconds)
            tracks.append(Track(ino: String(i), ext: ".wav", size: app.size(url), duration: Double(seconds), start: i == 0 ? 0 : 100))
        }
        player.setSpeed(1.5)
        player.start(Now(item: id, ep: nil, title: "Skip parity: 100 + 50 seconds", author: "Local synthetic audio", tracks: tracks), 110, play: false, generation: app.playbackGeneration)
    }

    /// A stalled UI test can let playback run to 150, which marks the book finished and makes
    /// the next Play start over from 0. A seed is a new listen at `t`, so clear that first.
    @MainActor private func reseed(_ t: Double) {
        skips.reset()
        if let n = player.now, app.progressDisk.local[n.key]?.isFinished == true {
            app.push(n, t, finished: false, restarting: true)
        }
        player.seek(t)
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
        let (track, offset, global) = actual()
        let item = player.p.currentItem
        return String(format: "track=%@;offset=%.3f;actual=%.3f;pos=%.3f;rate=%.2f;speed=%.2f;default=%.2f;paused=%@;ready=%@;local=%@;remote=%@;jump=%@",
                      track, offset, global, player.pos, player.p.rate, player.speed, player.p.defaultRate,
                      player.p.timeControlStatus == .paused && !player.playing ? "yes" : "no",
                      item?.status == .readyToPlay ? "yes" : "no",
                      (item?.asset as? AVURLAsset)?.url.isFileURL == true ? "yes" : "no", remoteStatus, skips.latched)
    }
}

/// Actual AVQueuePlayer file ("0" is 0..<100s, "1" is 100..<150s) and time.
@MainActor private func actual() -> (track: String, offset: Double, global: Double) {
    let url = (player.p.currentItem?.asset as? AVURLAsset)?.url
    let track = url?.deletingPathExtension().lastPathComponent ?? "none"
    let offset = player.p.currentTime().seconds
    return (track, offset, offset + (track == "1" ? 100 : 0))
}

/// Latches where the first skip made during playback actually landed, so a slow UI test read
/// still sees it after playback has moved on:
/// `jump=from:fromRate:track:actual:rate:speed:after:slack`.
/// It watches only the actual AVQueuePlayer: model position ticks briefly report a rebuilt
/// queue's file start.
@MainActor private final class SkipLatch {
    private(set) var latched = "none"
    private var last: (track: String, global: Double, rate: Float, moving: Bool, at: Date)?
    private var pending: (from: Double, rate: Float, at: Date)?
    private var landing: (track: String, global: Double, slack: Double, at: Date)?
    private var run: Date?

    /// Fixture seeds start a new step.
    func reset() { latched = "none"; last = nil; pending = nil; landing = nil; run = nil }

    func observe() {
        let (track, _, global) = actual()
        let rate = player.p.rate, moving = player.p.timeControlStatus == .playing, now = Date()
        defer { last = (track, global, rate, moving, now) }
        guard latched == "none", let last else { return }
        // Anything but continuous progress at the playing rate is a jump. Playback from file 0
        // into file 1 is continuous in book time however long the sampling gap; a real skip
        // across that boundary never is. NaN (no item) never counts as continuous.
        let gap = now.timeIntervalSince(last.at)
        let drift = abs(global - last.global - (last.moving ? Double(last.rate) : 0) * gap)
        let switched = track != last.track && !(last.track == "0" && track == "1" && drift < 0.5)
        let jumped = switched || !(drift < 0.5)
        if pending == nil {
            // Only a file switch or a 5s jump is a skip, not an audio hiccup. Seeds and skips
            // while paused are covered by the exact paused checks.
            guard switched || !(drift < 5), last.moving, last.rate == player.speed else { return }
            pending = (last.global, last.rate, last.at)
        }
        guard let skip = pending else { return }
        // The landing is the first reading after the latest seek-sized jump (a file switch or 5s,
        // as a queue rebuild then seek makes), never a later one: a stall that only lags playback
        // before it settles must not move it forward. Playback may already have run since the
        // jump for up to the sampling gap; `slack` bounds how far that reading can be past it.
        if jumped, landing == nil || switched || !(drift < 5) {
            landing = (track, global, Double(max(rate, last.rate, player.speed)) * gap, now)
        }
        // Judge once playback settled: ready on a file, at speed, progressing without a jump
        // for a full second. A seek in flight restarts the run and moves the landing.
        if jumped || !moving || player.p.currentItem?.status != .readyToPlay || rate != player.speed { run = nil }
        else if run == nil { run = now }
        if let run, let landing, now.timeIntervalSince(run) >= 1 {
            latched = String(format: "%.3f:%.2f:%@:%.3f:%.2f:%.2f:%.3f:%.3f", skip.from, skip.rate, landing.track,
                             landing.global, rate, player.speed, landing.at.timeIntervalSince(skip.at), landing.slack)
        }
    }
}
private final class BookSkipLoginProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "book-skip-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/login" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = Data(#"{"user":{"id":"skip-fixture-user","username":"skip-fixture","accessToken":"fixture","refreshToken":"refresh-fixture"}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
