import Foundation

/// Per-file state survives termination; five automatic retries, then an explicit user retry.
struct DownloadRetry: Codable {
    var attempts = 0
    var refreshToken = false
    var next: Date?
    var error: String?

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
        let reason = code >= 400 ? "HTTP \(code)" : cause?.localizedDescription ?? "Incomplete file"
        if Self.transient(cause, code: code), attempts < 5 {
            attempts += 1
            next = now.addingTimeInterval(max(min(60, pow(2, Double(attempts))), Self.retryAfter(retryAfter, now: now)))
            error = nil
        } else {
            next = nil
            error = "\(reason). Tap Retry to continue."
        }
    }
}
