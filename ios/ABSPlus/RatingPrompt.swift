import Foundation

/// Asks for an App Store rating with Apple's own prompt and nothing of ours in front of it (#205). The value moment is a
/// finished book: once 2 are finished and the app has been opened on 3 different days, the first at least 3 days ago,
/// the next book to finish asks when playback has stopped and the user is back in the app. At most twice per install,
/// the second time 120+ days later on a newer build: no store says whether the user rated, so the cap is how
/// "not now" is respected. Nothing leaves the device. Same rule as RatingPrompt.kt, whose test covers it.
@MainActor enum RatingPrompt {
    private static let d = UserDefaults.standard
    private static let day: TimeInterval = 86_400
    /// in memory only: a book that ended before the app was killed doesn't ask on the next launch
    private static var pending = false

    static func due(now: TimeInterval, first: TimeInterval, days: Int, books: Int, asked: Int, last: TimeInterval, lastVersion: Int, version: Int) -> Bool {
        days >= 3 && now - first >= 3 * day && books >= 2 &&
            (asked == 0 || asked == 1 && now - last >= 120 * day && version > lastVersion)
    }

    /// The app is on screen: counts the day
    static func used() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard d.double(forKey: "rating.day") != today else { return }
        d.set(today, forKey: "rating.day")
        d.set(d.integer(forKey: "rating.days") + 1, forKey: "rating.days")
        if d.object(forKey: "rating.first") == nil { d.set(Date().timeIntervalSince1970, forKey: "rating.first") }
    }

    /// A book played to its end
    static func finished() {
        d.set(d.integer(forKey: "rating.books") + 1, forKey: "rating.books")
        pending = true
    }

    /// Called while the user is in the app with playback stopped: true once after a book finished, if `due`
    static func ask() -> Bool {
        guard pending else { return false }
        pending = false
        let now = Date().timeIntervalSince1970
        let version = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        let asked = d.integer(forKey: "rating.asked")
        guard due(now: now, first: d.object(forKey: "rating.first") as? Double ?? now, days: d.integer(forKey: "rating.days"),
                  books: d.integer(forKey: "rating.books"), asked: asked, last: d.double(forKey: "rating.last"),
                  lastVersion: d.integer(forKey: "rating.version"), version: version) else { return false }
        d.set(asked + 1, forKey: "rating.asked")
        d.set(now, forKey: "rating.last")
        d.set(version, forKey: "rating.version")
        return true
    }
}
