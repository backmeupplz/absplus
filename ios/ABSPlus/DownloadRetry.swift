import Foundation

/// Per-file state survives termination; five automatic retries, then an explicit user retry.
struct DownloadRetry: Codable {
    /// Why automatic retries stopped. Stored as a reason, not text, so the message follows the current language.
    enum Failure: Codable, Equatable { case http(Int), expired, tls, interrupted }

    var attempts = 0
    var refreshToken = false
    var next: Date?
    var failure: Failure?

    /// The message for `failure`, in the current language.
    var error: String? {
        guard let failure else { return nil }
        let reason = switch failure {
        case .http(let code): "HTTP \(code)"
        case .expired: String(localized: "Sign in again", comment: "Download failure reason: the session expired")
        case .tls: String(localized: "Secure connection failed. Check the server's certificate", comment: "Download failure reason: the server's TLS certificate was rejected (no final period: \". Tap Retry to continue.\" follows)")
        case .interrupted: String(localized: "Transfer interrupted or file unavailable", comment: "Download failure reason")
        }
        return String(localized: "\(reason). Tap Retry to continue.", comment: "Download error after automatic retries; %@ = reason (e.g. HTTP 404). \"Retry\" is the button label")
    }

    // Server certificate rejections only: the generic .secureConnectionFailed is also what a handshake cut by the network
    // gives, and the client certificate codes aren't about the server's certificate.
    private static let tlsCodes: [URLError.Code] = [.serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid]

    // Error descriptions can contain request URLs or authorization data. Persist only the reason.
    static func failure(_ cause: Error?, code: Int) -> Failure {
        if code >= 300 { return .http(code) }
        if cause is Expired { return .expired }
        if let e = cause as? URLError, tlsCodes.contains(e.code) { return .tls }
        return .interrupted
    }

    static func transient(_ error: Error?, code: Int) -> Bool {
        if code == 401 || code == 408 || code == 429 || (500...599).contains(code) { return true }
        guard let e = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                .dataNotAllowed, .cancelled].contains(e.code)
    }

    static func retryAfter(_ value: String?, now: Date) -> TimeInterval {
        guard let value else { return 0 }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(seconds, Date.distantFuture.timeIntervalSince(now)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(0, f.date(from: value).map { $0.timeIntervalSince(now) } ?? 0)
    }

    mutating func fail(_ cause: Error?, code: Int, retryAfter: String?, now: Date = Date()) {
        if Self.transient(cause, code: code), attempts < 5 {
            attempts += 1
            next = now.addingTimeInterval(max(min(60, pow(2, Double(attempts))), Self.retryAfter(retryAfter, now: now)))
            failure = nil
        } else {
            next = nil
            failure = Self.failure(cause, code: code)
        }
    }
}

extension DownloadRetry {
    private enum Legacy: String, CodingKey { case error }

    /// Older builds stored the message itself under "error"; keep such a title stopped, re-rendered from its reason.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        refreshToken = try c.decodeIfPresent(Bool.self, forKey: .refreshToken) ?? false
        next = try c.decodeIfPresent(Date.self, forKey: .next)
        failure = try c.decodeIfPresent(Failure.self, forKey: .failure)
        if failure == nil, let old = try decoder.container(keyedBy: Legacy.self).decodeIfPresent(String.self, forKey: .error) {
            failure = old.hasPrefix("HTTP ") ? Int(old.dropFirst(5).prefix(3)).map(Failure.http) ?? .interrupted
                : Self.signInAgain.contains { old.hasPrefix($0) } ? .expired : .interrupted
        }
    }

    /// "Sign in again" in every language the app ships: an older build stored it in the language of that moment.
    private static let signInAgain = Set(["Sign in again"] + Bundle.main.localizations.compactMap {
        Bundle.main.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:))?.localizedString(forKey: "Sign in again", value: nil, table: nil)
    })
}
