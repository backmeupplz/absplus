import AVFoundation
import MediaPlayer
import UIKit

@MainActor let player = Player(source: app)

/// A screen owns preparation only; leaving it must not stop committed playback.
@MainActor final class PlaybackRequest {
    private let owner = UUID()
    private var task: Task<Void, Never>?
    private var pending: String?
    private var generation = UUID()

    func play(_ card: Card) {
        begin(card.key) { await player.playCard(card, owner: self.owner) }
    }

    func play(_ now: Now) {
        begin(now.key) { await player.play(now, owner: self.owner) }
    }

    private func begin(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        guard pending != key else { return }
        cancel()
        let request = UUID()
        generation = request
        pending = key
        task = Task {
            await work()
            if generation == request { task = nil; pending = nil }
        }
    }

    func cancel() {
        generation = UUID()
        pending = nil
        task?.cancel()
        task = nil
        player.cancelPreparation(owner: owner)
    }
}

/// One title at a time, its files queued as one timeline. Progress goes to the server every 20s, on pause and at the end.
@MainActor @Observable final class Player {
    @ObservationIgnored let p = AVQueuePlayer()
    @ObservationIgnored let source: Abs
    var now: Now?
    var pos: Double = 0
    var playing = false
    var preparing: String?
    @ObservationIgnored private var preparationOwner: UUID?
    var buffering = false
    var playbackError: String?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var queueID = UUID()
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
    @ObservationIgnored private var scope: UUID?
    @ObservationIgnored private var lastRetry = Date.distantPast
    @ObservationIgnored private var obs: [NSKeyValueObservation] = []

    init(source: Abs) {
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
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(30); return .success }
        c.skipBackwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-30); return .success }
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
        buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
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
        guard let n = now, let generation = scope, valid(generation) else { return }
        if Date().timeIntervalSince(lastRetry) < 30 {
            buffering = false
            playbackError = "Playback failed: \(e?.localizedDescription ?? "unknown error")"
            source.toast = playbackError
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
            playbackError = nil
            index = [:] // ignore end notifications from the previous listen
            pos = 0
            source.push(n, 0, finished: false, restarting: true)
            Task { await queue(n, 0, 0, play: true, generation: generation) }
            return
        }
        if playbackError != nil, let n = now {
            playbackError = nil
            let (i, off) = n.at(pos)
            Task { await queue(n, i, off, play: true, generation: generation) }
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

    func skip(_ s: Double) {
        guard let n = now else { return }
        seek(min(max(0, pos + s), n.duration - 1))
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
        preparationOwner = nil
        requestID = UUID(); queueID = UUID(); preparing = nil; choices = nil; buffering = false; playbackError = nil
        p.removeAllItems()
        index = [:]
        now = nil
        scope = nil
        choices = nil
        info()
    }

    // --- starting a title

    private func valid(_ generation: UUID) -> Bool {
        generation == source.playbackGeneration && source.me != nil && !Task.isCancelled
    }

    func playCard(_ c: Card, owner: UUID) async {
        let generation = source.playbackGeneration
        guard valid(generation) else { return }
        let request = UUID()
        requestID = request
        preparationOwner = owner
        preparing = c.key
        choices = nil
        defer { if requestID == request { preparing = nil } }
        do {
            let it = try await source.item(c.id)
            guard requestID == request, valid(generation) else { return }
            let n: Now
            if let ep = c.ep {
                guard let e = it.media.episodes?.first(where: { $0.id == ep }), let af = e.audioFile else { throw Msg(errorDescription: "Episode not found") }
                n = Now(item: c.id, ep: ep, title: e.title ?? "", author: it.card.title, tracks: [af.track(0)])
            } else {
                n = Now(item: c.id, ep: nil, title: c.title, author: c.sub, tracks: (it.media.tracks ?? []).map { $0.track() })
            }
            await prepare(n, request, generation: generation)
        } catch { if requestID == request, valid(generation) { source.say(error) } }
    }

    func play(_ n: Now, owner: UUID) async {
        let generation = source.playbackGeneration
        guard valid(generation) else { return }
        let request = UUID()
        requestID = request
        preparationOwner = owner
        preparing = n.key
        choices = nil
        defer { if requestID == request { preparing = nil } }
        await prepare(n, request, generation: generation)
    }

    func cancelPreparation(owner: UUID) {
        guard preparationOwner == owner else { return }
        requestID = UUID()
        preparationOwner = nil
        preparing = nil
        choices = nil
    }

    private func prepare(_ n: Now, _ request: UUID, generation: UUID) async {
        if n.tracks.isEmpty { source.toast = "No audio"; return }
        let ps = await source.positions(n)
        guard requestID == request, valid(generation) else { return }
        guard !ps.isEmpty else { return }
        if ps.count == 1 { start(n, ps[0].time, generation: generation) }
        else { choices = ResumeChoices(title: n, positions: ps, generation: generation, request: request) }
    }

    func resume(_ choice: ResumeChoices, at index: Int) {
        guard valid(choice.generation), requestID == choice.request, choice.positions.indices.contains(index) else { return }
        start(choice.title, choice.positions[index].time, generation: choice.generation)
    }

    /// After an app restart: put the last title back in the player, paused, at its latest position.
    func restore() async {
        let generation = source.playbackGeneration
        guard now == nil, valid(generation), let n = source.loadNow() else { return }
        let request = requestID
        let t = await source.positions(n).first?.time ?? 0
        if now == nil && requestID == request { start(n, t, play: false, generation: generation) }
    }

    func start(_ n: Now, _ t: Double, play: Bool = true, generation: UUID) {
        guard valid(generation), !n.tracks.isEmpty else { return }
        requestID = UUID()
        preparationOwner = nil
        preparing = nil
        choices = nil
        queueID = UUID()
        playbackError = nil
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
        let request = UUID()
        queueID = request
        buffering = play
        let auth = (try? await source.token()).map { ["Authorization": "Bearer " + $0] } ?? [:]
        guard valid(generation), now == n, scope == generation, queueID == request else { return }
        p.removeAllItems()
        index = [:]
        for k in i..<n.tracks.count {
            let asset = AVURLAsset(url: source.url(n.item, n.tracks[k]), options: ["AVURLAssetHTTPHeaderFieldsKey": auth])
            let it = AVPlayerItem(asset: asset)
            it.audioTimePitchAlgorithm = .timeDomain
            index[it] = k
            p.insert(it, after: nil)
        }
        idx = i
        if off > 0 { _ = await p.seek(to: CMTime(seconds: off, preferredTimescale: 1000)) }
        guard valid(generation), now == n, scope == generation, queueID == request else { return }
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
