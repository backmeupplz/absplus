import Foundation
import Security
import CryptoKit

struct Track: Codable, Hashable {
    var ino: String, ext: String, size: Int64, duration: Double, start: Double
}

struct Now: Codable, Equatable {
    var item: String, ep: String?, title: String, author: String, tracks: [Track]
    var key: String { ep.map { "\(item)/\($0)" } ?? item }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    /// book time (s) -> (track index, offset s)
    func at(_ t: Double) -> (Int, Double) {
        let i = tracks.lastIndex { $0.start <= t } ?? 0
        return (i, t - tracks[i].start)
    }
}

/// Anything shown as a tile/row: a library item, or a podcast episode when `ep` is set.
struct Card: Codable, Hashable {
    var id: String, title: String, sub: String, ep: String? = nil
    var key: String { ep.map { "\(id)/\($0)" } ?? id }
}

struct Pos { var who: String, time: Double, at: Double }

// --- server json (only the fields we use)

/// "ino" is a string on current servers; accept a number too
struct Flex: Codable, Hashable {
    var s: String
    func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(s) }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let v = try? c.decode(String.self) { s = v } else { s = String(try c.decode(Int64.self)) }
    }
}

struct AudioFile: Codable {
    struct M: Codable { var ext: String?, size: Int64? }
    var ino: Flex, metadata: M?, duration: Double?, startOffset: Double?
    func track(_ start: Double? = nil) -> Track {
        Track(ino: ino.s, ext: metadata?.ext ?? "", size: metadata?.size ?? 0, duration: duration ?? 0, start: start ?? startOffset ?? 0)
    }
}

struct Episode: Codable { var id: String, title: String?, publishedAt: Double?, audioFile: AudioFile? }

struct Item: Codable {
    struct Meta: Codable { var title: String?, authorName: String?, author: String?, description: String? }
    struct Media: Codable { var metadata: Meta, tracks: [AudioFile]?, episodes: [Episode]? }
    var id: String, mediaType: String?, media: Media, recentEpisode: Episode?
    var card: Card {
        let m = media.metadata
        return Card(id: id, title: m.title ?? "", sub: m.authorName.flatMap { $0.isEmpty ? nil : $0 } ?? m.author ?? "")
    }
}

struct Library: Decodable {
    struct S: Decodable { var coverAspectRatio: Int? }
    var id: String, name: String, mediaType: String?, settings: S?
}
struct Libraries: Decodable { var libraries: [Library] }
struct Results<T: Decodable>: Decodable { var results: [T] }
struct Series: Decodable { var id: String, name: String, books: [Item] }
struct InProgress: Decodable { var libraryItems: [Item] }
struct Prog: Codable { var libraryItemId: String, episodeId: String?, progress: Double?, currentTime: Double?, isFinished: Bool?, lastUpdate: Double? }
struct Bookmark: Decodable { var libraryItemId: String, title: String? }
struct Me: Decodable { var mediaProgress: [Prog], bookmarks: [Bookmark]? }
struct LoginResp: Decodable {
    struct U: Decodable { var id: String?; var username: String, accessToken: String?, token: String?, refreshToken: String? }
    var user: U
}

struct Tok: Codable, Equatable {
    var a: String, r: String
    var host: String? = nil
    var id: String = UUID().uuidString // login generation, NOT the server account identity
    var userID: String? = nil
    var mediaID: String? = nil // persisted random fallback if /login omits user.id
}
struct Hist: Codable { var card: Card, at: Double }

struct HttpErr: LocalizedError {
    let code: Int
    var retryAfter: String? = nil
    var errorDescription: String? { code == 401 ? "Unauthorized (401)" : code == 403 ? "Not allowed (403)" : "HTTP \(code)" }
}
struct Expired: LocalizedError { var epoch: String? = nil; var errorDescription: String? { "Session expired, please log in again" } }
struct Msg: LocalizedError { let errorDescription: String? }

func fmt(_ s: Double) -> String {
    let t = Int(max(0, s))
    return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
}

func ms() -> Double { Date().timeIntervalSince1970 * 1000 }

let dlDir: URL = {
    var u = URL.applicationSupportDirectory.appending(path: "dl")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    var v = URLResourceValues()
    v.isExcludedFromBackup = true // re-downloadable, keep it out of iCloud backups
    try? u.setResourceValues(v)
    return u
}()

/// resume data of interrupted downloads, one file per download path
let resumeDir: URL = {
    let u = URL.applicationSupportDirectory.appending(path: "resume")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

@MainActor let app = Abs()

/// Server API, accounts, downloads, progress. Settings live in UserDefaults, login tokens in the Keychain.
@MainActor @Observable final class Abs {
    @ObservationIgnored let d: UserDefaults
    @ObservationIgnored let progressFile: URL
    @ObservationIgnored let usesKeychain: Bool
    @ObservationIgnored var progressDisk = ProgressDisk()
    @ObservationIgnored var progressReady = false
    @ObservationIgnored var progressTask: Task<Void, Never>?
    @ObservationIgnored var progressWorker = UUID()
    @ObservationIgnored var replayingProgress = false
    @ObservationIgnored var accountGeneration = UUID()
    // Credentials may rotate without revoking an already-playing title.
    @ObservationIgnored var playbackGeneration = UUID()
    // General JSON belongs to a persisted login, not the stable retained-media owner.
    // Legacy json/ and account-json/ remain quarantined even if cleanup fails.
    var cacheDir: URL {
        let identity = me.flatMap { accts[$0] }.flatMap { $0.host == server ? $0.id : nil } ?? "locked"
        return URL.applicationSupportDirectory.appending(path: "session-json/" + identity)
    }

    /// set when the server can't be reached; cleared by the next successful request
    var offline = false
    var expired = false
    var toast: String?
    var me: String? { didSet { d.set(me, forKey: "me") } }
    var accts: [String: Tok] = [:] { didSet { if usesKeychain { kcWrite(accts) }; pruneProgress() } }
    /// latest known progress per key, from /api/me plus our own pushes
    var progress: [String: Prog] = [:]
    /// favorites, newest first; favq = {id: on/off} changes not yet on the server
    var fav: [Card] = [] { didSet { store("fav", fav) } }
    var favq: [String: Bool] = [:] { didSet { store("favq", favq) } }
    var hist: [Hist] = [] { didSet { store("hist", hist) } }
    /// item id -> linked usernames whose progress follows ours
    var shares: [String: [String]] = [:] { didSet { store("shares", shares); pruneProgress() } }
    /// download paths ("item/inoext") still transferring; dlv bumps when downloads change
    var inflight = Set<String>()
    var dlv = 0
    /// titles being downloaded, oldest first; kept across launches so unfinished ones carry on
    var dlq: [Now] = [] { didSet {
        let keys = Set(dlq.map(\.key))
        queueIDs = queueIDs.filter { keys.contains($0.key) }
        for n in dlq where queueIDs[n.key] == nil { queueIDs[n.key] = UUID() }
        persistDownloads()
    } }
    @ObservationIgnored private var queueIDs: [String: UUID] = [:]
    func queueID(_ n: Now) -> UUID? { queueIDs[n.key] }
    var dlRetry: [String: DownloadRetry] = [:] { didSet { persistDownloads() } }
    @ObservationIgnored private var retryWake: Task<Void, Never>?
    @ObservationIgnored private var fetching = Set<UUID>()

    /// bytes received so far per download path
    var got: [String: Int64] = [:]
    /// Current process-only transfer ownership, independent of the persisted title queue.
    @ObservationIgnored var transfers: [String: String] = [:]
    @ObservationIgnored private var dlMemo: [String: Bool] = [:]
    @ObservationIgnored private var refreshing: [String: Task<String, Error>] = [:]
    @ObservationIgnored private var pushingFavs = false

    @ObservationIgnored private var mediaServer: String?
    @ObservationIgnored private var mediaAccount: String?
    private(set) var mediaEpoch = UserDefaults.standard.string(forKey: "mediaEpoch") ?? UUID().uuidString
    var mediaScope: String {
        guard let server = mediaServer, let account = mediaAccount else { return "locked" }
        // Unambiguous pair encoding; the new root quarantines legacy server-only/unscoped
        // bytes in place, without deleting or adopting them.
        let identity = try! JSONEncoder().encode([server, account])
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    var mediaDir: URL { dlDir.appending(path: "accounts/" + mediaScope) }
    private var audioDir: URL { mediaDir.appending(path: "audio") }
    private func selectMedia(_ s: String?, _ tok: Tok? = nil) {
        mediaServer = s; mediaAccount = tok?.mediaID; mediaEpoch = UUID().uuidString
        d.set(mediaEpoch, forKey: "mediaEpoch"); dlMemo = [:]; dlv += 1
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    private func expanded(_ path: String) -> Bool { path.hasPrefix("/api/items/") && path.hasSuffix("?expanded=1") }
    private func retainedFile(_ path: String) -> URL { mediaDir.appending(path: "metadata/" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()) }

    @ObservationIgnored private var loginAttempt = UUID()
    @ObservationIgnored private var linkedAttempts: [String: UUID] = [:]
    @ObservationIgnored lazy var network = URLSession(configuration: .ephemeral, delegate: NoRedirects.shared, delegateQueue: nil)

    func checkSession(_ epoch: String) throws {
        try Task.checkCancellation()
        guard epoch == mediaEpoch else { throw CancellationError() }
    }

    var server: String { d.string(forKey: "server") ?? "" }

    init(defaults: UserDefaults = .standard, progressFile: URL = URL.applicationSupportDirectory.appending(path: "progress.json"), accounts: [String: Tok]? = nil) {
        d = defaults
        self.progressFile = progressFile
        usesKeychain = accounts == nil
        me = defaults.string(forKey: "me")
        mediaEpoch = defaults.string(forKey: "mediaEpoch") ?? UUID().uuidString
        // (property observers don't run in init)
        // Unbound legacy credentials cannot safely be migrated by guessing their host.
        accts = (accounts ?? Abs.kcRead()).filter { $0.value.host == defaults.string(forKey: "server") && $0.value.host != nil }
        if let name = me, accts[name] == nil { me = nil; d.removeObject(forKey: "me") }
        if usesKeychain { kcWrite(accts) }
        fav = load("fav") ?? []
        favq = load("favq") ?? [:]
        hist = load("hist") ?? []
        shares = load("shares") ?? [:]
        // Foreground tasks do not survive process termination. Never adopt background tasks.
        transfers = [:]
        d.removeObject(forKey: "transfers")
        if me == nil {
            // Quarantine legacy session metadata too; retained media remains on disk.
            fav = []; favq = [:]; hist = []; shares = [:]; dlq = []; transfers = [:]
            for key in d.dictionaryRepresentation().keys where key.hasPrefix("pos:") || key.hasPrefix("ratio:") || ["now", "lib", "fav", "favq", "hist", "shares", "dlq", "transfers"].contains(key) { d.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: resumeDir)
        }
        if me == nil && !accts.isEmpty { // the Keychain outlives a reinstall
            accts = [:]
            if usesKeychain { kcWrite([:]) }
        }
        if let name = me, var tok = accts[name], !server.isEmpty {
            if tok.mediaID == nil {
                // Legacy caches have no proven account binding. Preserve, but never adopt.
                tok.mediaID = tok.userID.map { "user:" + $0 } ?? "login:" + UUID().uuidString
                accts[name] = tok
                if usesKeychain { kcWrite(accts) } // init property observers are not a persistence guarantee
            }
            mediaServer = server; mediaAccount = tok.mediaID
            d.set(mediaEpoch, forKey: "mediaEpoch")
        }
        // Unowned legacy queues are not evidence of which account authorized the work.
        if let me, let tok = accts[me], let saved: DownloadQueue = load("downloadQueue"), saved.owner == tok.id {
            dlq = saved.titles
            for n in dlq { queueIDs[n.key] = UUID() }
            let paths = Set(dlq.flatMap { n in n.tracks.map { rel(n.item, $0) } })
            dlRetry = saved.retries.filter { paths.contains($0.key) }
        } else { d.removeObject(forKey: "downloadQueue") }
        for key in ["dlq", "dlRetry", "transfers"] { d.removeObject(forKey: key) }
        // Old resume archives may contain redirected requests and credentials.
        try? FileManager.default.removeItem(at: resumeDir)
        try? FileManager.default.createDirectory(at: resumeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        progressReady = true
        restoreProgress()
    }

    private struct DownloadQueue: Codable {
        var owner: String
        var titles: [Now]
        var retries: [String: DownloadRetry]
    }
    private func persistDownloads() {
        guard let me, let tok = accts[me], tok.host == server else { d.removeObject(forKey: "downloadQueue"); return }
        store("downloadQueue", DownloadQueue(owner: tok.id, titles: dlq, retries: dlRetry))
    }

    private func load<T: Decodable>(_ k: String) -> T? { d.data(forKey: k).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private func store<T: Encodable>(_ k: String, _ v: T) { d.set(try? JSONEncoder().encode(v), forKey: k) }

    func say(_ e: Error) {
        if e is CancellationError || (e as? URLError)?.code == .cancelled { return }
        if let e = e as? Expired, let epoch = e.epoch, epoch != mediaEpoch { return }
        toast = e.localizedDescription
        if e is Expired { expired = true }
    }

    // --- http

    func http(_ method: String, _ path: String, _ body: [String: Any]? = nil, _ hdr: [String: String] = [:], base: String, epoch: String, account: (String, String)? = nil, report: Bool = true) async throws -> Data {
        try checkSession(epoch)
        if let (name, id) = account { guard accts[name]?.id == id else { throw CancellationError() } }
        guard path.hasPrefix("/"), let url = URL(string: base + path), url.host == URL(string: base)?.host, url.scheme == URL(string: base)?.scheme, url.port == URL(string: base)?.port else { throw Msg(errorDescription: "Invalid server URL") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        hdr.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, resp) = try await network.data(for: r)
            try checkSession(epoch)
            if let (name, id) = account { guard accts[name]?.id == id else { throw CancellationError() } }
            if report { offline = false }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw HttpErr(code: code, retryAfter: (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) }
            return data
        } catch {
            try checkSession(epoch)
            if let (name, id) = account { guard accts[name]?.id == id else { throw CancellationError() } }
            if report, let e = error as? URLError, e.code != .cancelled { offline = true }
            throw error
        }
    }

    func ping() async { if (try? await http("GET", "/ping", base: server, epoch: mediaEpoch)) != nil { startProgressReplay() } }

    // --- accounts

    private func credentials(_ data: Data, host: String) throws -> (String, Tok) {
        let u = try JSONDecoder().decode(LoginResp.self, from: data).user
        let access = u.accessToken.flatMap { $0.isEmpty ? nil : $0 } ?? u.token ?? ""
        guard !u.username.isEmpty, !access.isEmpty else { throw Msg(errorDescription: "Missing access token") }
        let userID = u.id.flatMap { $0.isEmpty ? nil : $0 }
        return (u.username, Tok(a: access, r: u.refreshToken ?? "", host: host, userID: userID,
                                mediaID: userID.map { "user:" + $0 } ?? "login:" + UUID().uuidString))
    }

    /// Authenticate a candidate without modifying the active session. Only the latest live attempt may commit.
    @discardableResult func login(_ url: String, _ user: String, _ pass: String, main: Bool) async throws -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URLComponents(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              u.host != nil, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { throw Msg(errorDescription: "Invalid server URL") }
        let epoch = mediaEpoch, attempt = UUID(), name = user.trimmingCharacters(in: .whitespaces)
        if main { loginAttempt = attempt } else {
            guard me != nil, !expired, s == server else { throw CancellationError() }
            linkedAttempts[name] = attempt
        }
        let r: Data
        do {
            r = try await http("POST", "/login", ["username": name, "password": pass], ["x-return-tokens": "true"], base: s, epoch: epoch, report: false)
        } catch {
            try checkSession(epoch)
            guard main ? loginAttempt == attempt : linkedAttempts[name] == attempt else { throw CancellationError() }
            if (error as? HttpErr)?.code == 401 { throw Msg(errorDescription: "Wrong username or password") }
            throw error
        }
        let (actual, tok) = try credentials(r, host: s)
        try checkSession(epoch)
        guard main ? loginAttempt == attempt : linkedAttempts[name] == attempt else { throw CancellationError() }
        if main {
            let old = me.flatMap { accts[$0] }
            let same = s == server && actual == me && tok.userID != nil && tok.userID == old?.userID
            resetSession(preservePlayback: same)
            d.set(s, forKey: "server")
            selectMedia(s, tok)
            accts = [actual: tok]
            me = actual
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } else {
            guard !expired, actual != me else { throw Msg(errorDescription: "That's you") }
            refreshing.removeValue(forKey: actual)?.cancel()
            accts[actual] = tok
        }
        progressReady = true
        pruneProgress()
        progress = progressDisk.local
        startProgressReplay()
        return actual
    }

    /// Capture the token's immutable origin before removing it; never resolve a later global server.
    func unlink(_ name: String) {
        guard name != me else { return }
        // The server may canonicalize any entered alias; its pending result is not known yet.
        linkedAttempts.removeAll()
        refreshing.removeValue(forKey: name)?.cancel()
        let epoch = mediaEpoch
        let tok = accts.removeValue(forKey: name)
        shares = shares.mapValues { $0.filter { $0 != name } }
        if let tok, let host = tok.host {
            Task { _ = try? await http("POST", "/logout", [:], ["x-refresh-token": tok.r], base: host, epoch: epoch, report: false) }
        }
    }

    var accounts: [String] { accts.keys.filter { $0 != me }.sorted() }

    private func resetSession(preservePlayback: Bool = false) {
        accountGeneration = UUID()
        progressReady = false
        progressTask?.cancel(); progressTask = nil; progressWorker = UUID()
        if !preservePlayback { playbackGeneration = UUID(); clearProgress() }
        cancel(Set(transfers.keys).union(dlRetry.keys)) // completed media is retained
        retryWake?.cancel(); retryWake = nil; fetching = []
        refreshing.values.forEach { $0.cancel() }; refreshing = [:]
        loginAttempt = UUID(); linkedAttempts = [:]
        if !preservePlayback { player.clear() }; Covers.clear()
        dlq = []; dlRetry = [:]; inflight = []; got = [:]; transfers = [:]
        d.removeObject(forKey: "downloadQueue")
        try? FileManager.default.removeItem(at: resumeDir) // archives contain old credentials
        try? FileManager.default.createDirectory(at: resumeDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("pos:") || key.hasPrefix("ratio:") || ["now", "lib"].contains(key) { if !preservePlayback || key != "now" { d.removeObject(forKey: key) } }
        accts = [:]; progress = [:]; fav = []; favq = [:]; hist = []; shares = [:]
        pushingFavs = false; offline = false; expired = false; toast = nil; me = nil
    }

    func logout() {
        resetSession()
        d.removeObject(forKey: "server")
        selectMedia(nil)
        progressReady = true
        pruneProgress()
    }

    private func exp(_ t: String) -> Double {
        let parts = t.split(separator: ".")
        guard parts.count > 1 else { return .greatestFiniteMagnitude }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        guard let data = Data(base64Encoded: b), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = j["exp"] as? Double else { return .greatestFiniteMagnitude }
        return e
    }

    /// A valid access token for `name`, refreshing it if less than `fresh` seconds of it are left.
    func token(_ name: String? = nil, fresh: Double = 60, force: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard let name = name ?? me, let a = accts[name], a.host == server else { throw Expired(epoch: mediaEpoch) }
        let epoch = mediaEpoch
        if !force && exp(a.a) - Date().timeIntervalSince1970 > fresh { return a.a }
        if let t = refreshing[name] {
            let value: String
            do { value = try await t.value } catch { try checkSession(epoch); guard accts[name]?.id == a.id else { throw CancellationError() }; throw error }
            try checkSession(epoch)
            guard accts[name]?.id == a.id else { throw CancellationError() }
            return value
        }
        let t = Task {
            defer { if epoch == mediaEpoch, accts[name]?.id == a.id { refreshing[name] = nil } }
            do {
                let data = try await http("POST", "/auth/refresh", [:], ["x-refresh-token": a.r], base: a.host!, epoch: epoch, account: (name, a.id))
                let (actual, value) = try credentials(data, host: a.host!)
                guard actual == name, value.userID == nil || value.userID == a.userID else { throw Expired(epoch: mediaEpoch) }
                // Refresh cannot establish a different media identity.
                var tok = value; tok.id = a.id; tok.userID = a.userID; tok.mediaID = a.mediaID
                accts[name] = tok
                return tok.a
            } catch let e as HttpErr where e.code == 401 {
                if name == me { throw Expired(epoch: mediaEpoch) }
                throw e
            }
        }
        refreshing[name] = t
        let value: String
        do { value = try await t.value } catch { try checkSession(epoch); guard accts[name]?.id == a.id else { throw CancellationError() }; throw error }
        try checkSession(epoch)
        guard accts[name]?.id == a.id else { throw CancellationError() }
        return value
    }

    func api(_ method: String, _ path: String, _ body: [String: Any]? = nil, name: String? = nil) async throws -> Data {
        let epoch = mediaEpoch
        guard let name = name ?? me, let a = accts[name], let host = a.host, host == server else { throw Expired(epoch: mediaEpoch) }
        let auth = try await token(name)
        return try await http(method, path, body, ["Authorization": "Bearer " + auth], base: host, epoch: epoch, account: (name, a.id))
    }

    // --- json cache, so screens render instantly and work offline

    private func cacheFile(_ path: String) -> URL {
        cacheDir.appending(path: String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" }))
    }
    func cached(_ path: String) -> Data? {
        guard me != nil else { return nil }
        if let data = try? Data(contentsOf: cacheFile(path)) { return data }
        guard mediaServer == server, me != nil, expanded(path) else { return nil }
        return try? Data(contentsOf: retainedFile(path))
    }
    func get(_ path: String) async throws -> Data {
        let epoch = mediaEpoch
        let data = try await api("GET", path)
        try checkSession(epoch)
        try? data.write(to: cacheFile(path), options: .atomic)
        if mediaServer == server, me != nil, expanded(path), let item = try? JSONDecoder().decode(Item.self, from: data) {
            let dst = retainedFile(path)
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(item).write(to: dst, options: .atomic)
        }
        return data
    }

    /// Renders cached JSON instantly, then refreshes from the server.
    func load<T: Decodable>(_ path: String, _ render: (T) -> Void) async {
        let epoch = mediaEpoch
        guard !Task.isCancelled else { return }
        let old = cached(path)
        if let old, let v = try? JSONDecoder().decode(T.self, from: old) { render(v) }
        do {
            let new = try await get(path)
            try checkSession(epoch)
            if new != old { render(try JSONDecoder().decode(T.self, from: new)) }
        } catch {
            guard epoch == mediaEpoch, !Task.isCancelled else { return }
            if (old == nil && !offline) || error is Expired { say(error) }
        }
    }

    func item(_ id: String) async throws -> Item {
        let path = "/api/items/\(id)?expanded=1"
        let data: Data
        if let c = cached(path) { data = c } else { data = try await get(path) }
        return try JSONDecoder().decode(Item.self, from: data)
    }

    // --- tracks & downloads

    private func component(_ s: String) -> String {
        // IDs/extensions are path components, not server-provided relative paths.
        if s == "." || s == ".." { return s.replacingOccurrences(of: ".", with: "%2E") }
        return s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? "invalid"
    }
    func rel(_ item: String, _ t: Track) -> String { "accounts/\(mediaScope)/audio/\(component(item))/\(component(t.ino + t.ext))" }
    func file(_ item: String, _ t: Track) -> URL { dlDir.appending(path: rel(item, t)) }
    func done(_ item: String, _ t: Track) -> Bool { size(file(item, t)) == t.size }
    func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) }
    func url(_ item: String, _ t: Track) -> URL {
        done(item, t) ? file(item, t) : URL(string: "\(server)/api/items/\(item)/file/\(t.ino)")!
    }

    func resumeFile(_ rel: String) -> URL { resumeDir.appending(path: rel.replacingOccurrences(of: "/", with: "_")) }

    /// queues a title and starts its missing files
    func download(_ n: Now) async {
        guard me != nil else { return }
        if !queued(n) { dlq.append(n) }
        for t in n.tracks { dlRetry[rel(n.item, t)] = nil }
        await fetch(n)
    }

    /// starts the files of a queued title that are neither on disk nor on their way, continuing interrupted ones
    func fetch(_ n: Now, queueID expected: UUID? = nil) async {
        guard let id = queueID(n), expected == nil || expected == id, me != nil else { return }
        dlChanged() // reconcile files saved before an interrupted completion callback
        guard queued(n) else { scheduleRetries(); return }
        guard fetching.insert(id).inserted else { return }
        defer { fetching.remove(id) }
        let epoch = mediaEpoch
        let host = server
        let pending = n.tracks.filter { t in
            let r = rel(n.item, t)
            return !done(n.item, t) && !inflight.contains(r) && dlRetry[r]?.error == nil && (dlRetry[r]?.next ?? .distantPast) <= Date()
        }
        guard !pending.isEmpty else { scheduleRetries(); return }
        do {
            let auth = "Bearer " + (try await token(fresh: 1800, force: pending.contains { dlRetry[rel(n.item, $0)]?.refreshToken == true }))
            guard !Task.isCancelled, epoch == mediaEpoch, host == server, me != nil, queueID(n) == id else { return }
            for t in pending where !done(n.item, t) && !inflight.contains(rel(n.item, t)) {
                let r = rel(n.item, t)
                if var retry = dlRetry[r] { retry.refreshToken = false; dlRetry[r] = retry }
                guard let url = URL(string: "\(host)/api/items/\(component(n.item))/file/\(component(t.ino))/download") else {
                    failed(r, Msg(errorDescription: "Invalid download URL"), code: 0); continue
                }
                if let data = try? Data(contentsOf: resumeFile(r)) {
                    try? FileManager.default.removeItem(at: resumeFile(r))
                    Downloader.shared.start(r, url, auth, resume: data)
                } else {
                    try? FileManager.default.removeItem(at: file(n.item, t))
                    Downloader.shared.start(r, url, auth)
                }
            }
            dlChanged()
        } catch {
            guard !Task.isCancelled, epoch == mediaEpoch, host == server, queueID(n) == id else { return }
            for t in pending { failed(rel(n.item, t), error, code: (error as? HttpErr)?.code ?? 0, retryAfter: (error as? HttpErr)?.retryAfter) }
            say(error)
        }
        scheduleRetries()
    }

    func failed(_ rel: String, _ error: Error?, code: Int, retryAfter: String? = nil) {
        var state = dlRetry[rel] ?? DownloadRetry()
        state.fail(error, code: code, retryAfter: retryAfter)
        state.refreshToken = state.refreshToken || code == 401
        dlRetry[rel] = state
        if let message = state.error { toast = "Download paused: " + message }
        scheduleRetries()
    }

    func downloadError(_ n: Now) -> String? {
        n.tracks.compactMap { dlRetry[rel(n.item, $0)]?.error }.first
    }
    func downloadWaiting(_ n: Now) -> Bool {
        n.tracks.contains { let r = rel(n.item, $0); return !inflight.contains(r) && dlRetry[r]?.next != nil }
    }

    /// In-process wakeups are advisory. Persisted deadlines remain authoritative after suspension/relaunch.
    func scheduleRetries() {
        retryWake?.cancel(); retryWake = nil
        let paths = Set(dlq.flatMap { n in n.tracks.map { rel(n.item, $0) } })
        guard me != nil, let next = dlRetry.filter({ paths.contains($0.key) && !inflight.contains($0.key) }).values.compactMap(\.next).min() else { return }
        let epoch = mediaEpoch
        retryWake = Task {
            // Cap each sleep (not the server deadline) to avoid overflow on untrusted Retry-After.
            do { try await Task.sleep(for: .seconds(min(3600, max(0.05, next.timeIntervalSinceNow)))) } catch { return }
            guard epoch == mediaEpoch, !Task.isCancelled else { return }
            retryWake = nil
            await resumeQueue()
        }
    }

    /// after a relaunch: carry on with queued titles, preserving file-specific budgets and deadlines
    func resumeQueue() async {
        let pending = dlq.compactMap { n in queueID(n).map { (n, $0) } }
        let epoch = mediaEpoch
        for (n, id) in pending {
            guard epoch == mediaEpoch, !Task.isCancelled else { return }
            await fetch(n, queueID: id)
        }
        scheduleRetries()
    }

    func queued(_ n: Now) -> Bool { dlq.contains { $0.key == n.key } }

    /// (bytes so far, total) of a title
    func dlBytes(_ n: Now) -> (Int64, Int64) {
        _ = dlv
        return n.tracks.reduce((0, 0)) { a, t in (a.0 + (done(n.item, t) ? t.size : got[rel(n.item, t)] ?? 0), a.1 + t.size) }
    }

    func dlChanged() {
        dlMemo = [:]
        dlv += 1
        for n in dlq {
            for t in n.tracks where done(n.item, t) {
                let r = rel(n.item, t)
                // A live transfer still owns its completion/error callback.
                guard transfers[r] == nil, !inflight.contains(r) else { continue }
                if dlRetry[r] != nil { dlRetry[r] = nil }
                got[r] = nil
                try? FileManager.default.removeItem(at: resumeFile(r))
            }
        }
        let left = dlq.filter { n in
            !n.tracks.allSatisfy { done(n.item, $0) } || n.tracks.contains { transfers[rel(n.item, $0)] != nil }
        }
        if left.count != dlq.count { dlq = left }
    }

    /// book fully downloaded / podcast has a downloaded episode (judged from the item page's cached json)
    func downloaded(_ id: String) -> Bool {
        _ = dlv
        if let m = dlMemo[id] { return m }
        var r = false
        if FileManager.default.fileExists(atPath: audioDir.appending(path: component(id)).path),
           let data = cached("/api/items/\(id)?expanded=1"), let it = try? JSONDecoder().decode(Item.self, from: data) {
            if let ts = it.media.tracks { r = !ts.isEmpty && ts.allSatisfy { done(id, $0.track()) } }
            else { r = (it.media.episodes ?? []).contains { $0.audioFile.map { done(id, $0.track(0)) } ?? false } }
        }
        dlMemo[id] = r
        return r
    }

    /// Episode cards require their own file, not a downloaded sibling.
    func downloaded(_ card: Card) -> Bool {
        guard let ep = card.ep else { return downloaded(card.id) }
        _ = dlv
        if let m = dlMemo[card.key] { return m }
        let it = cached("/api/items/\(card.id)?expanded=1").flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
        let r = it?.media.episodes?.first { $0.id == ep }?.audioFile.map { done(card.id, $0.track(0)) } ?? false
        dlMemo[card.key] = r
        return r
    }

    /// item folders that hold downloaded files, with their size
    func downloads() -> [(id: String, size: Int64)] {
        _ = dlv
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []).compactMap { dir in
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.isEmpty ? nil : (dir.lastPathComponent.removingPercentEncoding ?? dir.lastPathComponent, files.reduce(0) { $0 + max(0, size($1)) })
        }
    }

    /// title/author from the item page's cached json
    func cachedCard(_ id: String) -> Card {
        cached("/api/items/\(id)?expanded=1").flatMap { try? JSONDecoder().decode(Item.self, from: $0).card } ?? Card(id: id, title: "Unknown item", sub: "")
    }

    func removeAll(_ id: String) {
        let dir = audioDir.appending(path: component(id))
        let prefix = "accounts/\(mediaScope)/audio/\(component(id))/"
        let rels = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { prefix + $0 }
        cancel(Set(rels).union(inflight.filter { $0.hasPrefix(prefix) }).union(dlq.filter { $0.item == id }.flatMap { n in n.tracks.map { rel(n.item, $0) } }))
        dlq.removeAll { $0.item == id }
        try? FileManager.default.removeItem(at: dir)
        dlChanged()
    }

    /// cancels a title's download, or removes it once done
    func remove(_ n: Now) {
        cancel(Set(n.tracks.map { rel(n.item, $0) }))
        dlq.removeAll { $0.key == n.key }
        n.tracks.forEach { try? FileManager.default.removeItem(at: file(n.item, $0)) }
        let dir = audioDir.appending(path: component(n.item))
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true { try? FileManager.default.removeItem(at: dir) }
        dlChanged()
    }

    private func cancel(_ rels: Set<String>) {
        let descriptions = Set(rels.compactMap { transfers.removeValue(forKey: $0) })
        inflight.subtract(rels)
        rels.forEach { dlRetry[$0] = nil; got[$0] = nil; try? FileManager.default.removeItem(at: resumeFile($0)) }
        Downloader.shared.session.getAllTasks { ts in ts.filter { descriptions.contains($0.taskDescription ?? "") }.forEach { $0.cancel() } }
        scheduleRetries()
    }

    // --- what's playing, kept across app restarts

    func saveNow(_ n: Now) { store("now", n) }
    func loadNow() -> Now? { load("now") }

    // --- progress. Shared items get every update pushed to those linked accounts too.

    private func remote(_ name: String, _ key: String) async -> Prog? {
        guard let data = try? await api("GET", "/api/me/progress/\(key)", name: name),
              let p = try? JSONDecoder().decode(Prog.self, from: data) else { return nil }
        return p
    }

    /// First = where this account should resume; the rest = linked accounts that listened more recently elsewhere.
    func positions(_ n: Now) async -> [Pos] {
        let generation = accountGeneration
        var mine = Pos(who: "You", time: 0, at: 0)
        if let s = d.string(forKey: "pos:\(n.key)")?.split(separator: ","), s.count == 2, let t = Double(s[0]), let at = Double(s[1]) {
            mine = Pos(who: "You", time: t, at: at)
        }
        if let p = progressDisk.local[n.key] { mine = Pos(who: "You", time: p.isFinished == true ? 0 : p.currentTime ?? 0, at: p.lastUpdate ?? 0) }
        if let me, let r = await remote(me, n.key) {
            guard generation == accountGeneration else { return [] }
            mergeProgress(r, key: n.key)
            persistProgress()
            if let p = progressDisk.local[n.key], (p.lastUpdate ?? 0) >= mine.at {
                mine = Pos(who: "You", time: p.isFinished == true ? 0 : p.currentTime ?? 0, at: p.lastUpdate ?? 0)
            }
        }
        guard generation == accountGeneration else { return [] }
        var out = [mine]
        for a in shares[n.item] ?? [] {
            if let p = await remote(a, n.key) {
                guard generation == accountGeneration else { return [] }
                let r = Pos(who: a, time: p.isFinished == true ? 0 : p.currentTime ?? 0, at: p.lastUpdate ?? 0)
                if r.at > mine.at, abs(r.time - mine.time) > 30 { out.append(r) }
            }
        }
        return generation == accountGeneration ? out : []
    }

    func setMe(_ m: Me) {
        for p in m.mediaProgress {
            mergeProgress(p, key: p.episodeId.map { "\(p.libraryItemId)/\($0)" } ?? p.libraryItemId)
        }
        progress = progressDisk.local
        persistProgress()
        syncFavs(m.bookmarks ?? [])
    }

    /// 0...1, or nil if never started
    func pct(_ key: String) -> Double? { progress[key].map { $0.isFinished == true ? 1 : $0.progress ?? 0 } }

    // --- favorites: a per-user bookmark titled FAV on the item, so they sync across devices and work for podcasts too.

    private let FAV = "♥ Favorite"
    private let FAV_T = 0.001 // odd time so a real 0:00 bookmark is never touched

    func isFav(_ id: String) -> Bool { fav.contains { $0.id == id } }

    func toggleFav(_ c: Card) -> Bool {
        let on = !isFav(c.id)
        if on { fav.insert(c, at: 0) } else { fav.removeAll { $0.id == c.id } }
        favq[c.id] = on
        let epoch = mediaEpoch
        Task { guard epoch == mediaEpoch else { return }; await pushFavs() }
        return on
    }

    /// Uploads queued favorite changes.
    func pushFavs() async {
        let epoch = mediaEpoch
        if pushingFavs || Task.isCancelled { return }
        pushingFavs = true
        defer { if epoch == mediaEpoch { pushingFavs = false } }
        for (id, on) in favq {
            guard epoch == mediaEpoch, !Task.isCancelled else { return }
            var ok = true
            do {
                if on { _ = try await api("POST", "/api/me/item/\(id)/bookmark", ["time": FAV_T, "title": FAV]) }
                else { _ = try await api("DELETE", "/api/me/item/\(id)/bookmark/\(FAV_T)") }
            } catch let e as HttpErr where (400..<500).contains(e.code) { // e.g. already removed
            } catch { ok = false }
            guard epoch == mediaEpoch, !Task.isCancelled else { return }
            if ok && favq[id] == on { favq[id] = nil } // unless toggled again meanwhile
        }
    }

    /// server favorites + changes not uploaded yet -> local list (cards for new ids get filled in by fillFav)
    private func syncFavs(_ bookmarks: [Bookmark]) {
        let server = bookmarks.filter { $0.title == FAV }.map(\.libraryItemId)
        let ids = Set(server + favq.filter { $0.value }.keys).subtracting(favq.filter { !$0.value }.keys)
        var f = fav.filter { ids.contains($0.id) }
        for id in server where ids.contains(id) && !f.contains(where: { $0.id == id }) { f.append(Card(id: id, title: "", sub: "")) }
        if f != fav { fav = f }
        if !favq.isEmpty { let epoch = mediaEpoch; Task { guard epoch == mediaEpoch else { return }; await pushFavs() } }
    }

    /// title/author for a favorite added on another device
    func fillFav(_ id: String) async {
        guard let data = try? await get("/api/items/\(id)?expanded=1"), let c = try? JSONDecoder().decode(Item.self, from: data).card,
              let i = fav.firstIndex(where: { $0.id == id }) else { return }
        fav[i] = c
    }

    func addHistory(_ n: Now) {
        let c = Card(id: n.item, title: n.title, sub: n.author, ep: n.ep)
        hist = [Hist(card: c, at: ms())] + hist.filter { $0.card.key != c.key }.prefix(49)
    }

    // --- Keychain: {username: tokens}, this device only, readable while locked after first unlock

    private static let kq: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "absplus", kSecAttrAccount as String: "accounts"]

    private static func kcRead() -> [String: Tok] {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { ["--download-retry-test", "--isolation-test", "--retained-test", "--list-lifecycle-test", "--offline-home-test", "--offline-library-test", "--offline-series-test", "--accessibility-test"].contains($0) }) {
            return UserDefaults.standard.data(forKey: "fixture-accounts").flatMap { try? JSONDecoder().decode([String: Tok].self, from: $0) } ?? [:]
        }
#endif
        var q = kq
        q[kSecReturnData as String] = true
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let data = r as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: Tok].self, from: data)) ?? [:]
    }

    private func kcWrite(_ v: [String: Tok]) {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { ["--download-retry-test", "--isolation-test", "--retained-test", "--list-lifecycle-test", "--offline-home-test", "--offline-library-test", "--offline-series-test", "--accessibility-test"].contains($0) }) {
            d.set(try? JSONEncoder().encode(v), forKey: "fixture-accounts")
            return
        }
#endif
        SecItemDelete(Abs.kq as CFDictionary)
        var q = Abs.kq
        q[kSecValueData as String] = try? JSONEncoder().encode(v)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Foreground-only downloads: background URLSession always follows redirects, ignoring the
/// task delegate. Ephemeral transport can reject them. No suspended/terminated background
/// continuity is promised; persisted title queues restart missing files on the next launch.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloader()
    private var reported: [String: Date] = [:]
    private var fileErrors: [Int: Error] = [:]
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    @MainActor func start(_ rel: String, _ url: URL, _ auth: String, resume: Data? = nil) {
        let t: URLSessionDownloadTask
        if let resume, let safe = Self.reauth(resume, auth, expected: url) { t = session.downloadTask(withResumeData: safe) }
        else {
            var r = URLRequest(url: url)
            r.setValue(auth, forHTTPHeaderField: "Authorization")
            t = session.downloadTask(with: r)
        }
        bind(t, rel)
        t.resume()
    }

    /// A new transfer of the same path must never inherit its cancelled predecessor's callbacks.
    @MainActor func bind(_ task: URLSessionTask, _ rel: String) {
        let description = app.mediaEpoch + "|" + UUID().uuidString + "|" + rel
        task.taskDescription = description
        app.transfers[rel] = description
        app.inflight.insert(rel)
    }

    @MainActor private func activeRel(_ task: URLSessionTask) -> String? {
        guard app.me != nil, let desc = task.taskDescription else { return nil }
        let parts = desc.components(separatedBy: "|")
        guard parts.count == 3, parts[0] == app.mediaEpoch,
              app.transfers[parts[2]] == desc else { return nil }
        return parts[2]
    }

    // Reconnect only to cancel obsolete OS-owned tasks on upgrade. Never adopt their
    // callbacks or files, and never share this session's delegate with active downloads.
    private lazy var legacySession = URLSession(
        configuration: .background(withIdentifier: "com.borodutch.absplus.dl"))
    private var retiredLegacy = false
    func retireLegacyDownloads() {
        guard !retiredLegacy else { return }
        retiredLegacy = true
        legacySession.invalidateAndCancel()
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite _: Int64) {
        guard let rel = MainActor.assumeIsolated({ activeRel(t) }), Date().timeIntervalSince(reported[rel] ?? .distantPast) > 0.5 else { return }
        reported[rel] = Date()
        MainActor.assumeIsolated { app.got[rel] = w }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        guard let rel = MainActor.assumeIsolated({ activeRel(t) }), (200...299).contains((t.response as? HTTPURLResponse)?.statusCode ?? 0) else { return }
        let dst = dlDir.appending(path: rel)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: loc, to: dst)
        } catch { fileErrors[t.taskIdentifier] = error }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        let fileError = fileErrors.removeValue(forKey: task.taskIdentifier)
        guard let rel = MainActor.assumeIsolated({ activeRel(task) }) else { return }
        let response = task.response as? HTTPURLResponse
        let code = response?.statusCode ?? 0
        reported[rel] = nil
        MainActor.assumeIsolated {
            app.inflight.remove(rel)
            app.transfers[rel] = nil
            app.got[rel] = nil
            guard let n = app.dlq.first(where: { q in q.tracks.contains { app.rel(q.item, $0) == rel } }),
                  let track = n.tracks.first(where: { app.rel(n.item, $0) == rel }) else { return }
            if e == nil, fileError == nil, (200...299).contains(code), app.done(n.item, track) {
                app.dlRetry[rel] = nil
                try? FileManager.default.removeItem(at: app.resumeFile(rel))
            } else {
                if let resume = (e as? URLError)?.downloadTaskResumeData, code != 401 {
                    try? resume.write(to: app.resumeFile(rel))
                }
                let error = e ?? fileError ?? ((200...299).contains(code) || code == 0 ? URLError(.networkConnectionLost) : nil)
                app.failed(rel, error, code: code, retryAfter: response?.value(forHTTPHeaderField: "Retry-After"))
            }
            app.dlChanged()
            app.scheduleRetries()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // Resume data is an archive holding the original request, token included. A file resumed after the token's
    // one-hour lifetime would get a 401, so the saved requests get the current token. Unexpected formats or mismatched URLs are discarded.
    private static let root = "NSKeyedArchiveRootObjectKey" // the key these archives use (not NSKeyedArchiveRootObjectKey, which is "root")

    static func reauth(_ data: Data, _ auth: String, expected: URL) -> Data? {
        func open<T>(_ d: Data, _ classes: [AnyClass]) -> T? {
            (try? NSKeyedUnarchiver(forReadingFrom: d))?.decodeObject(of: classes, forKey: root) as? T
        }
        func pack(_ o: Any) -> Data {
            let a = NSKeyedArchiver(requiringSecureCoding: true)
            a.encode(o, forKey: root)
            a.finishEncoding()
            return a.encodedData
        }
        guard let dict: NSDictionary = open(data, [NSDictionary.self, NSString.self, NSNumber.self, NSData.self, NSDate.self]) else { return nil }
        let m = NSMutableDictionary(dictionary: dict)
        for k in ["NSURLSessionResumeCurrentRequest", "NSURLSessionResumeOriginalRequest"] {
            guard let d = m[k] as? Data, let r: NSURLRequest = open(d, [NSURLRequest.self]), let req = r.mutableCopy() as? NSMutableURLRequest else { return nil }
            guard req.url == expected else { return nil }
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            m[k] = pack(req)
        }
        return pack(m)
    }
}

/// Do not forward passwords, refresh headers, bearer tokens, or request bodies through redirects.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
