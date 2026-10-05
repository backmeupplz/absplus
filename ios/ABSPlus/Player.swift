import AVFoundation
import MediaPlayer
import UIKit

@MainActor let player = Player(source: app)

/// One title at a time, its files queued as one timeline. Progress goes to the server every 20s, on pause and at the end.
@MainActor @Observable final class Player {
    @ObservationIgnored let p = AVQueuePlayer()
    @ObservationIgnored let source: Abs
    var now: Now?
    var pos: Double = 0
    var playing = false
    var speed: Float = UserDefaults.standard.object(forKey: "speed") as? Float ?? 1
    /// a choice of resume positions to offer (linked accounts are ahead)
    struct ResumeChoices {
        let title: Now
        let positions: [Pos]
        let generation: UUID
        let request: UUID
    }
    var choices: ResumeChoices?
    static let speeds: [Float] = [1, 1.25, 1.5, 1.75, 2, 0.8]

    @ObservationIgnored private var index: [AVPlayerItem: Int] = [:]
    @ObservationIgnored private var idx = 0
    @ObservationIgnored private var mediaLoads: [MediaLoader] = []
    @ObservationIgnored private var scope: UUID?
    @ObservationIgnored private var lastRetry = Date.distantPast
    @ObservationIgnored private var obs: [NSKeyValueObservation] = []

    init(source: Abs = app) {
        self.source = source
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
        guard let n = now, p.currentItem != nil, let generation = scope, valid(generation) else { return }
        if Date().timeIntervalSince(lastRetry) < 30 {
            source.toast = "Playback failed: \(e?.localizedDescription ?? "unknown error")"
            return
        }
        lastRetry = Date()
        let (i, off) = n.at(pos)
        Task { await queue(n, i, off, play: true, generation: generation) }
    }

    private func sync(finished: Bool = false) {
        guard let n = now, scope == source.playbackGeneration else { return }
        let at = finished ? n.duration : pos
        source.push(n, at, finished: finished)
    }

    // --- control

    func play() {
        guard let generation = scope, valid(generation) else { return }
        if let n = now, source.progressDisk.local[n.key]?.isFinished == true {
            index = [:] // ignore end notifications from the previous listen
            pos = 0
            source.push(n, 0, finished: false, restarting: true)
            Task { await queue(n, 0, 0, play: true, generation: generation) }
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        if p.currentItem == nil, let n = now { // finished: start over
            Task { await queue(n, 0, 0, play: true, generation: generation) }
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
        guard let n = now, let generation = scope, valid(generation) else { return }
        let (i, off) = n.at(t)
        pos = t
        if i == idx && p.currentItem != nil { p.seek(to: CMTime(seconds: off, preferredTimescale: 1000)) { _ in } }
        else { Task { await queue(n, i, off, play: playing, generation: generation) } }
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
        now = nil; playing = false; pos = 0
        mediaLoads.forEach { $0.cancel() }; mediaLoads = []
        scope = nil
        choices = nil
        info()
    }

    // --- starting a title

    func playCard(_ c: Card) async {
        let generation = source.playbackGeneration, request = source.accountGeneration
        do {
            let it = try await source.item(c.id)
            guard valid(generation), request == source.accountGeneration else { return }
            if let ep = c.ep {
                guard let e = it.media.episodes?.first(where: { $0.id == ep }), let af = e.audioFile else { throw Msg(errorDescription: "Episode not found") }
                await play(Now(item: c.id, ep: ep, title: e.title ?? "", author: it.card.title, tracks: [af.track(0)]), generation: generation)
            } else {
                await play(Now(item: c.id, ep: nil, title: c.title, author: c.sub, tracks: (it.media.tracks ?? []).map { $0.track() }), generation: generation)
            }
        } catch { if valid(generation) { source.say(error) } }
    }

    // Expired credentials prompt reauth but do not revoke an already-authorized local player.
    private func valid(_ generation: UUID) -> Bool {
        generation == source.playbackGeneration && source.me != nil && !Task.isCancelled
    }

    func play(_ n: Now) async {
        await play(n, generation: source.playbackGeneration)
    }

    private func play(_ n: Now, generation: UUID) async {
        guard valid(generation) else { return }
        if n.tracks.isEmpty { source.toast = "No audio"; return }
        let request = source.accountGeneration
        let ps = await source.positions(n)
        guard valid(generation), request == source.accountGeneration, !ps.isEmpty else { return }
        if ps.count == 1 { start(n, ps[0].time, generation: generation) }
        else { choices = ResumeChoices(title: n, positions: ps, generation: generation, request: request) }
    }

    func resume(_ choice: ResumeChoices, at index: Int) {
        guard valid(choice.generation), choice.request == source.accountGeneration, choice.positions.indices.contains(index) else { return }
        choices = nil
        start(choice.title, choice.positions[index].time, generation: choice.generation)
    }

    /// After an app restart: put the last title back in the player, paused, at its latest position.
    func restore() async {
        let generation = source.playbackGeneration
        guard now == nil, valid(generation), let n = source.loadNow() else { return }
        let request = source.accountGeneration
        guard let t = await source.positions(n).first?.time, request == source.accountGeneration else { return }
        if now == nil { start(n, t, play: false, generation: generation) }
    }

    func start(_ n: Now, _ t: Double, play: Bool = true) { start(n, t, play: play, generation: source.playbackGeneration) }

    func start(_ n: Now, _ t: Double, play: Bool = true, generation: UUID) {
        guard valid(generation), !n.tracks.isEmpty else { return }
        if let old = now, old.key != n.key, p.currentItem != nil, scope == source.playbackGeneration {
            let at = pos
            source.push(old, at, finished: false)
        }
        now = n
        scope = generation
        source.saveNow(n)
        if play { source.addHistory(n) }
        let (i, off) = n.at(t > n.duration - 5 ? 0 : t)
        pos = n.tracks[i].start + off
        // Passive restore keeps completion; an explicit play starts a new listen.
        if play, source.progressDisk.local[n.key]?.isFinished == true {
            index = [:]
            source.push(n, pos, finished: false, restarting: true)
        }
        Task {
            await queue(n, i, off, play: play, generation: generation)
            guard valid(generation), now == n else { return }
            _ = await Covers.get(n.item) // lock screen artwork
            guard valid(generation), now == n else { return }
            info()
        }
    }

    private func queue(_ n: Now, _ i: Int, _ off: Double, play: Bool, generation: UUID) async {
        guard valid(generation), now == n, scope == generation else { return }
        var auth = try? await source.token()
        // A same-account reauth can cancel an old refresh without revoking this player.
        if auth == nil, valid(generation) { auth = try? await source.token() }
        guard valid(generation), now == n, scope == generation else { return }
        mediaLoads.forEach { $0.cancel() }; mediaLoads = []
        p.removeAllItems()
        index = [:]
        for k in i..<n.tracks.count {
            let url = source.url(n.item, n.tracks[k])
            let asset: AVURLAsset
            if url.isFileURL { asset = AVURLAsset(url: url) }
            else {
                guard let auth else { return }
                let loader = MediaLoader(url: url, token: auth, epoch: source.mediaEpoch, source: source, playback: generation)
                mediaLoads.append(loader)
                asset = loader.asset
            }
            let it = AVPlayerItem(asset: asset)
            it.audioTimePitchAlgorithm = .timeDomain
            index[it] = k
            p.insert(it, after: nil)
        }
        idx = i
        if off > 0 { _ = await p.seek(to: CMTime(seconds: off, preferredTimescale: 1000)) }
        guard valid(generation), now == n, scope == generation else { return }
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
