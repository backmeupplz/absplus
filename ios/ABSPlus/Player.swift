import AVFoundation
import MediaPlayer
import UIKit

@MainActor let player = Player()

/// One title at a time, its files queued as one timeline. Progress goes to the server every 20s, on pause and at the end.
@MainActor @Observable final class Player {
    @ObservationIgnored let p = AVQueuePlayer()
    var now: Now?
    var pos: Double = 0
    var playing = false
    var speed: Float = UserDefaults.standard.object(forKey: "speed") as? Float ?? 1
    /// a choice of resume positions to offer (linked accounts are ahead)
    var choices: (Now, [Pos])?
    static let speeds: [Float] = [1, 1.25, 1.5, 1.75, 2, 0.8]

    @ObservationIgnored private var index: [AVPlayerItem: Int] = [:]
    @ObservationIgnored private var idx = 0
    @ObservationIgnored private var lastRetry = Date.distantPast
    @ObservationIgnored private var obs: [NSKeyValueObservation] = []

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        p.defaultRate = speed
        p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        obs.append(p.observe(\.timeControlStatus) { [weak self] p, _ in
            DispatchQueue.main.async { self?.status() }
        })
        obs.append(p.observe(\.currentItem?.status) { [weak self] p, _ in
            DispatchQueue.main.async {
                if let it = self?.p.currentItem, it.status == .failed { self?.failed(it.error) }
            }
        })
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let item = n.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.ended(item) }
        }
        nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.failed(e) }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            // after a call or Siri, carry on if the system says so
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            let ended = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            if ended && opts?.contains(.shouldResume) == true { MainActor.assumeIsolated { self?.play() } }
        }
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.p.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.remoteSkipForward() ?? .commandFailed }
        c.skipBackwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.remoteSkipBackward() ?? .commandFailed }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            self?.seek((e as! MPChangePlaybackPositionCommandEvent).positionTime)
            return .success
        }
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        Task {
            while true {
                try? await Task.sleep(for: .seconds(20))
                if p.timeControlStatus == .playing { sync() }
            }
        }
    }

    private var bookPos: Double {
        guard let n = now, idx < n.tracks.count else { return 0 }
        let t = p.currentTime().seconds
        return n.tracks[idx].start + (t.isFinite ? t : 0)
    }

    private func tick() {
        guard now != nil, p.currentItem != nil else { return }
        pos = bookPos
    }

    private func status() {
        let was = playing
        playing = p.timeControlStatus != .paused
        if was && !playing && p.currentItem != nil { sync() }
        info()
    }

    private func ended(_ item: AVPlayerItem?) {
        guard let item, let i = index[item], let n = now else { return }
        if i == n.tracks.count - 1 {
            pos = n.duration
            sync(finished: true)
        } else {
            idx = i + 1
        }
    }

    /// Streams fail when the access token expires mid-book or the network drops: rebuild the queue with a fresh token.
    private func failed(_ e: Error?) {
        guard let n = now else { return }
        if Date().timeIntervalSince(lastRetry) < 30 {
            app.toast = "Playback failed: \(e?.localizedDescription ?? "unknown error")"
            return
        }
        lastRetry = Date()
        let (i, off) = n.at(pos)
        Task { await queue(n, i, off, play: true) }
    }

    private func sync(finished: Bool = false) {
        guard let n = now else { return }
        let at = finished ? n.duration : pos
        Task { await app.push(n, at, finished: finished) }
    }

    // --- control

    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if p.currentItem == nil, let n = now { // finished: start over
            Task { await queue(n, 0, 0, play: true) }
            return
        }
        p.play()
    }

    func toggle() { playing ? p.pause() : play() }

    // Shared by MPRemoteCommandCenter and the local regression fixture.
    func remoteSkipForward() -> MPRemoteCommandHandlerStatus { skip(30); return .success }
    func remoteSkipBackward() -> MPRemoteCommandHandlerStatus { skip(-30); return .success }

    func skip(_ s: Double) {
        guard let n = now else { return }
        seek(min(max(0, pos + s), n.duration))
    }

    func seek(_ t: Double) {
        guard let n = now else { return }
        let (i, off) = n.at(t)
        pos = t
        if i == idx && p.currentItem != nil { p.seek(to: CMTime(seconds: off, preferredTimescale: 1000)) { _ in } }
        else { Task { await queue(n, i, off, play: playing) } }
        info()
    }

    func setSpeed(_ s: Float) {
        speed = s
        p.defaultRate = s
        if p.timeControlStatus != .paused { p.rate = s }
        UserDefaults.standard.set(s, forKey: "speed")
        info()
    }

    func nextSpeed() { setSpeed(Self.speeds[((Self.speeds.firstIndex(of: speed) ?? -1) + 1) % Self.speeds.count]) }

    func clear() {
        p.removeAllItems()
        index = [:]
        now = nil
        info()
    }

    // --- starting a title

    func playCard(_ c: Card) async {
        do {
            let it = try await app.item(c.id)
            if let ep = c.ep {
                guard let e = it.media.episodes?.first(where: { $0.id == ep }), let af = e.audioFile else { throw Msg(errorDescription: "Episode not found") }
                await play(Now(item: c.id, ep: ep, title: e.title ?? "", author: it.card.title, tracks: [af.track(0)]))
            } else {
                await play(Now(item: c.id, ep: nil, title: c.title, author: c.sub, tracks: (it.media.tracks ?? []).map { $0.track() }))
            }
        } catch { app.say(error) }
    }

    func play(_ n: Now) async {
        if n.tracks.isEmpty { app.toast = "No audio"; return }
        let ps = await app.positions(n)
        if ps.count == 1 { start(n, ps[0].time) } else { choices = (n, ps) }
    }

    /// After an app restart: put the last title back in the player, paused, at its latest position.
    func restore() async {
        guard now == nil, app.me != nil, let n = app.loadNow() else { return }
        let t = await app.positions(n).first?.time ?? 0
        if now == nil { start(n, t, play: false) }
    }

    func start(_ n: Now, _ t: Double, play: Bool = true) {
        if let old = now, old.key != n.key, p.currentItem != nil {
            let at = pos
            Task { await app.push(old, at, finished: false) }
        }
        now = n
        app.saveNow(n)
        if play { app.addHistory(n) }
        let (i, off) = n.at(t > n.duration - 5 ? 0 : t)
        pos = n.tracks[i].start + off
        Task {
            await queue(n, i, off, play: play)
            _ = await Covers.get(n.item) // lock screen artwork
            info()
        }
    }

    private func queue(_ n: Now, _ i: Int, _ off: Double, play: Bool) async {
        let auth = (try? await app.token()).map { ["Authorization": "Bearer " + $0] } ?? [:]
        guard now == n else { return }
        p.removeAllItems()
        index = [:]
        for k in i..<n.tracks.count {
            let asset = AVURLAsset(url: app.url(n.item, n.tracks[k]), options: ["AVURLAssetHTTPHeaderFieldsKey": auth])
            let it = AVPlayerItem(asset: asset)
            it.audioTimePitchAlgorithm = .timeDomain
            index[it] = k
            p.insert(it, after: nil)
        }
        idx = i
        if off > 0 { _ = await p.seek(to: CMTime(seconds: off, preferredTimescale: 1000)) }
        pos = n.tracks[i].start + off
        if play {
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play()
        }
        info()
    }

    // --- lock screen / control center

    private func info() {
        guard let n = now else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var i: [String: Any] = [
            MPMediaItemPropertyTitle: n.title,
            MPMediaItemPropertyArtist: n.author,
            MPMediaItemPropertyPlaybackDuration: n.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: pos,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if let img = Covers.mem(n.item) { i[MPMediaItemPropertyArtwork] = Self.artwork(img) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = i
    }

    /// the handler runs on a background queue, so it must not be main-actor isolated
    nonisolated static func artwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }
}
