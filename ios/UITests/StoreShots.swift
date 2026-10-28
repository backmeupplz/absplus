import XCTest

/// The six store screenshots in one language, against a real server: home with Continue listening, the library's cover
/// grid, a book page, the player, a podcast and the series list. ios/store-shots.sh runs it for every store language.
/// Run with TEST_RUNNER_ABS_URL, TEST_RUNNER_ABS_USER, TEST_RUNNER_ABS_PASS, TEST_RUNNER_SHOTS (output folder) and
/// TEST_RUNNER_STORE_LANG (a language in Localizable.xcstrings, e.g. de, pt-BR or zh-Hans; default en) set, plus
/// TEST_RUNNER_STORE_LOCALE (e.g. de_DE) for number and date formats. Starts best from a fresh install, so the book
/// page says Play and the player starts at the beginning in every language. TEST_RUNNER_DUO_INNER=1 takes an iPhone Duo's
/// inner display, which shows the app in landscape: the test has store-shots.sh unfold the Duo.
final class StoreShots: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    let app = XCUIApplication()
    lazy var language = env["STORE_LANG"] ?? "en"
    lazy var inner = env["DUO_INNER"] == "1"
    let book = "Volume 01", podcast = "Librivox"

    /// The app's own translation of an English string, read from the string catalog next to this file
    lazy var catalog: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ABSPlus/Localizable.xcstrings")
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }()

    func t(_ english: String) -> String {
        let entry = catalog[english] as? [String: Any]
        let localized = (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
        return (localized?["stringUnit"] as? [String: Any])?["value"] as? String ?? english
    }

    lazy var out: String = {
        let out = env["SHOTS"] ?? "/tmp/absplus-shots"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        return out
    }()

    /// The test runner doesn't launch on an unfolded Duo, so it starts folded and leaves an `unfold` file for
    /// store-shots.sh, which unfolds the simulator and removes the file
    func unfold() {
        let flag = "\(out)/unfold"
        FileManager.default.createFile(atPath: flag, contents: nil)
        for _ in 0..<60 where FileManager.default.fileExists(atPath: flag) { sleep(1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag), "store-shots.sh didn't unfold the Duo")
        sleep(3) // the switch to the inner display is animated
    }

    func shot(_ name: String) {
        sleep(3) // let covers load
        // XCUIScreen.main is always the Duo's cover display; the inner one is the larger screen
        let shots = (inner ? XCUIScreen.screens : [XCUIScreen.main]).map { $0.screenshot() }
        let screenshot = shots.max { $0.image.size.width * $0.image.size.height < $1.image.size.width * $1.image.size.height }!
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    func wait(_ e: XCUIElement, timeout: Double = 30, line: UInt = #line) {
        if e.waitForExistence(timeout: timeout) { return }
        shot("zz-fail")
        print(app.debugDescription)
        XCTFail("missing \(e)", line: line)
    }

    func tap(_ e: XCUIElement, timeout: Double = 30, line: UInt = #line) {
        wait(e, timeout: timeout, line: line)
        e.tap()
    }

    /// Taps a tab by its place: on the Duo's inner display a tab can be reported as not hittable, and then a plain tap
    /// does nothing
    func tapTab(_ name: String, line: UInt = #line) {
        let e = app.tab(name)
        wait(e, line: line)
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func label(_ s: String) -> XCUIElement { app.buttons.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }

    /// Signs in with the app in English, so the system's offer to save the password is the one dismissed below
    func signIn() {
        app.launch()
        let url = app.textFields["Server URL"]
        if url.waitForExistence(timeout: 10) {
            url.tap()
            url.typeText(env["ABS_URL"]!)
            tap(app.textFields["Username"])
            app.typeText(env["ABS_USER"]!)
            tap(app.secureTextFields["Password"])
            app.typeText(env["ABS_PASS"]!)
            tap(app.buttons["Sign in"])
            for a in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] where a.buttons["Not Now"].waitForExistence(timeout: 5) {
                a.buttons["Not Now"].tap()
                break
            }
            wait(app.tab("Library"))
        }
        app.terminate()
    }

    func testStoreShots() throws {
        continueAfterFailure = false
        if inner { unfold() }
        signIn()
        let locale = env["STORE_LOCALE"] ?? language.replacingOccurrences(of: "-", with: "_")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()

        // The demo's first library holds Aesop's Fables (twelve volumes, one series) and its podcast library one podcast
        tapTab(t("Library"))
        wait(label(book))
        shot("2-library")
        tap(label(book))
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", [t("Play"), t("Resume")])).firstMatch
        wait(play)
        shot("3-book")
        play.tap()
        sleep(4)

        tap(app.otherElements["mini"])
        wait(app.buttons[t("Pause")])
        sleep(6) // a few seconds in, so the timeline shows progress
        shot("4-player")
        app.swipeDown(velocity: .fast)

        // on the Duo's inner display the player is a sheet, and the first tap after it can go nowhere
        for _ in 0..<3 {
            tapTab(t("Home"))
            sleep(1)
            if app.tab(t("Home")).isSelected { break }
        }
        wait(app.staticTexts[t("Continue listening")])
        shot("1-home")

        tapTab(t("Series"))
        wait(app.staticTexts.firstMatch)
        let loading = app.descendants(matching: .any)["loading.initial"]
        _ = loading.waitForNonExistence(timeout: 30)
        shot("6-series")

        // the podcast library, through the title menu at the library's root
        tapTab(t("Library"))
        tapTab(t("Library")) // reselecting a tab pops to its root
        tap(app.barButton("Audiobooks")) // library names come from the server
        tap(app.buttons["Podcasts"])
        tap(label(podcast))
        wait(app.staticTexts[t("Episodes")])
        shot("5-podcast")
    }
}
