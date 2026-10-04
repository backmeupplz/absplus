import Foundation

/// One atomic snapshot contains local state and the outbox. Never contains credentials.
struct ProgressDisk: Codable {
    var server = ""
    var owner = ""
    var local: [String: Prog] = [:]
    var pending: [PendingProgress] = []
}

struct PendingProgress: Codable, Equatable {
    var id = UUID()
    var account: String
    var item: String
    var episode: String?
    var time: Double
    var duration: Double
    var finished: Bool
    var at: Double
    var attempts = 0
    var retryAt: Double = 0
    var sent: ProgressAttempt?
    var acknowledged: ProgressAttempt?
    var key: String { episode.map { "\(item)/\($0)" } ?? item }
    var prog: Prog { Prog(libraryItemId: item, episodeId: episode, progress: finished ? 1 : fraction,
                         currentTime: time, isFinished: finished, lastUpdate: at) }
    var fraction: Double { duration > 0 ? min(1, max(0, time / duration)) : 0 }
    var body: [String: Any] {
        var b: [String: Any] = ["currentTime": time, "duration": duration, "progress": fraction, "lastUpdate": at]
        // ABS treats explicit false as "mark unread": it discards currentTime.
        // Omit it during listening; ABS derives reread completion from position.
        if finished { b["isFinished"] = true }
        return b
    }
    static func delay(_ attempts: Int) -> Double { min(300, pow(2, Double(min(attempts, 9)))) }
}

struct ProgressAttempt: Codable, Equatable {
    var time: Double
    var finished: Bool
    var at: Double
    func matches(_ p: Prog, exact: Bool = false) -> Bool {
        p.currentTime == time && (p.isFinished ?? false) == finished &&
        (exact ? p.lastUpdate == at : (p.lastUpdate ?? 0) >= at)
    }
}

extension Abs {
    func restoreProgress() {
        if let data = try? Data(contentsOf: progressFile), let saved = try? JSONDecoder().decode(ProgressDisk.self, from: data) {
            progressDisk = saved
        }
        pruneProgress()
        progress = progressDisk.local
    }

    @discardableResult func persistProgress() -> Bool {
        do {
            try FileManager.default.createDirectory(at: progressFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(progressDisk).write(to: progressFile, options: .atomic)
            return true
        } catch {
            say(Msg(errorDescription: "Could not save listening progress: \(error.localizedDescription)"))
            return false
        }
    }

    func authorized(_ p: PendingProgress) -> Bool {
        progressDisk.server == server && progressDisk.owner == me && accts[p.account] != nil &&
        (p.account == me || (shares[p.item] ?? []).contains(p.account))
    }

    func pruneProgress() {
        guard progressReady else { return }
        var changed = false
        if progressDisk.server != server || progressDisk.owner != (me ?? "") {
            progressDisk = ProgressDisk(server: server, owner: me ?? "")
            progress = [:]
            changed = true
        }
        let allowed = progressDisk.pending.filter { authorized($0) }
        if allowed.count != progressDisk.pending.count {
            progressDisk.pending = allowed
            changed = true
        }
        if changed { persistProgress() }
    }

    func clearProgress() {
        progressTask?.cancel()
        progressDisk = ProgressDisk()
        progress = [:]
        persistProgress()
    }

    /// Resolve an uncertain send once; only that exact server version remains ours.
    @discardableResult private func observeAttempt(_ remote: Prog, account: String, key: String) -> Bool {
        guard let i = progressDisk.pending.firstIndex(where: { $0.account == account && $0.key == key }) else { return false }
        if progressDisk.pending[i].sent?.matches(remote) == true {
            progressDisk.pending[i].acknowledged = ProgressAttempt(time: remote.currentTime ?? 0, finished: remote.isFinished ?? false, at: remote.lastUpdate ?? 0)
            progressDisk.pending[i].sent = nil
        }
        return progressDisk.pending[i].acknowledged?.matches(remote, exact: true) == true
    }

    /// Reads use the same last-write-wins rule as replay. A server timestamp
    /// assigned to our own attempted write is not a new event from another device.
    func mergeProgress(_ remote: Prog, key: String) {
        let ours = observeAttempt(remote, account: me ?? "", key: key)
        let pending = progressDisk.pending.first { $0.account == me && $0.key == key }
        guard (remote.lastUpdate ?? 0) > (progressDisk.local[key]?.lastUpdate ?? -1),
              pending.map({ (remote.lastUpdate ?? 0) > $0.at && !ours }) ?? true else { return }
        progressDisk.local[key] = remote
        progress[key] = remote
        if let pending { progressDisk.pending.removeAll { $0.id == pending.id } }
    }

    /// Synchronous event capture: disk commit precedes scheduling network work.
    func push(_ n: Now, _ pos: Double, finished: Bool, restarting: Bool = false) {
        guard let me, accts[me] != nil, pos.isFinite, n.duration.isFinite else { return }
        pruneProgress()
        let at = max(ms(), (progressDisk.local[n.key]?.lastUpdate ?? 0) + 1)
        let done = finished || (!restarting && progressDisk.local[n.key]?.isFinished == true)
        for account in Set([me] + (shares[n.item] ?? [])).sorted() where accts[account] != nil {
            let old = progressDisk.pending.first { $0.account == account && $0.key == n.key }
            let p = PendingProgress(account: account, item: n.item, episode: n.ep, time: max(0, pos),
                                    duration: n.duration, finished: done, at: at,
                                    attempts: old?.attempts ?? 0, retryAt: old?.retryAt ?? 0,
                                    sent: old?.sent, acknowledged: old?.acknowledged)
            progressDisk.pending.removeAll { $0.account == account && $0.key == n.key }
            progressDisk.pending.append(p)
            if account == me { progressDisk.local[n.key] = p.prog; progress[n.key] = p.prog }
        }
        if persistProgress() { startProgressReplay() }
    }

    /// Relaunch/foreground/connectivity wake this worker without playing a title.
    func startProgressReplay() {
        guard progressTask == nil, !progressDisk.pending.isEmpty else { return }
        progressTask = Task { [weak self] in
            guard let self else { return }
            defer { self.progressTask = nil }
            while !Task.isCancelled && !self.progressDisk.pending.isEmpty {
                await self.replayProgress()
                guard !Task.isCancelled, let due = self.progressDisk.pending.map(\.retryAt).min() else { return }
                do { try await Task.sleep(for: .seconds(min(2, max(0.1, (due - ms()) / 1000)))) }
                catch { return }
            }
        }
    }

    /// Single-flight; each recipient is independently acknowledged/retried. ABS has
    /// no conditional PATCH: an external write between GET/PATCH cannot be fenced.
    func replayProgress() async {
        guard !replayingProgress else { return }
        replayingProgress = true
        defer { replayingProgress = false }
        pruneProgress()
        let generation = accountGeneration
        for entry in progressDisk.pending where entry.retryAt <= ms() {
            guard generation == accountGeneration, !Task.isCancelled, authorized(entry), progressDisk.pending.contains(where: { $0.id == entry.id }) else { continue }
            do {
                let remote = try await progressRemote(entry)
                guard generation == accountGeneration, !Task.isCancelled, authorized(entry), progressDisk.pending.contains(where: { $0.id == entry.id }) else { continue }
                let ours = remote.map { observeAttempt($0, account: entry.account, key: entry.key) } ?? false
                if let remote, (remote.lastUpdate ?? 0) > entry.at, !ours {
                    if entry.account == me {
                        progressDisk.local[entry.key] = remote
                        progress[entry.key] = remote
                    }
                    progressDisk.pending.removeAll { $0.id == entry.id }
                } else {
                    // Persist the attempted payload before sending: a lost response or
                    // process death must not mistake our server-created row for an
                    // external update on the next replay.
                    guard let sending = progressDisk.pending.firstIndex(where: { $0.id == entry.id }) else { continue }
                    progressDisk.pending[sending].sent = ProgressAttempt(time: entry.time, finished: entry.finished, at: entry.at)
                    guard persistProgress() else { return }
                    _ = try await progressAPI("PATCH", entry, entry.body)
                    guard generation == accountGeneration, !Task.isCancelled, authorized(entry) else { continue }
                    let acknowledged = try await progressRemote(entry)
                    guard generation == accountGeneration, !Task.isCancelled, authorized(entry) else { continue }
                    if let acknowledged { observeAttempt(acknowledged, account: entry.account, key: entry.key) }
                    if let i = progressDisk.pending.firstIndex(where: { $0.account == entry.account && $0.key == entry.key }) {
                        if progressDisk.pending[i].id == entry.id {
                            if entry.account == me, let acknowledged {
                                progressDisk.local[entry.key] = acknowledged
                                progress[entry.key] = acknowledged
                            }
                            progressDisk.pending.remove(at: i)
                        }
                    }
                }
                persistProgress()
            } catch {
                guard generation == accountGeneration, authorized(entry), let i = progressDisk.pending.firstIndex(where: { $0.account == entry.account && $0.key == entry.key }) else { continue }
                progressDisk.pending[i].attempts = min(10, progressDisk.pending[i].attempts + 1)
                progressDisk.pending[i].retryAt = ms() + PendingProgress.delay(progressDisk.pending[i].attempts) * 1000
                persistProgress()
                if error is Expired, entry.account == me { expired = true }
            }
        }
    }

    private func progressRemote(_ p: PendingProgress) async throws -> Prog? {
        do { return try JSONDecoder().decode(Prog.self, from: await progressAPI("GET", p)) }
        catch let e as HttpErr where e.code == 404 { return nil }
    }

    private func progressAPI(_ method: String, _ p: PendingProgress, _ body: [String: Any]? = nil) async throws -> Data {
        guard authorized(p), !Task.isCancelled else { throw CancellationError() }
        let path = "/api/me/progress/\(p.key)"
        let generation = accountGeneration
        do {
            let auth = try await token(p.account)
            guard generation == accountGeneration, authorized(p), progressDisk.pending.contains(where: { $0.account == p.account && $0.key == p.key }), !Task.isCancelled else { throw CancellationError() }
            return try await http(method, path, body, ["Authorization": "Bearer " + auth])
        }
        catch let e as HttpErr where e.code == 401 {
            _ = try await token(p.account, fresh: .infinity)
            guard generation == accountGeneration, authorized(p), progressDisk.pending.contains(where: { $0.account == p.account && $0.key == p.key }), !Task.isCancelled else { throw CancellationError() }
            return try await http(method, path, body, ["Authorization": "Bearer " + (accts[p.account]?.a ?? "")])
        }
    }
}
