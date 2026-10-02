import XCTest

/// Walks through the app against a real server and saves a screenshot of each screen.
/// Run with TEST_RUNNER_ABS_URL, TEST_RUNNER_ABS_USER, TEST_RUNNER_ABS_PASS and TEST_RUNNER_SHOTS (output folder) set.
final class Tour: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    let app = XCUIApplication()

    func shot(_ name: String) {
        sleep(2) // let covers load
        let out = env["SHOTS"] ?? "/tmp/absplus-shots"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    func wait(_ e: XCUIElement, timeout: Double = 20, line: UInt = #line) {
        if e.waitForExistence(timeout: timeout) { return }
        shot("zz-fail")
        print(app.debugDescription)
        XCTFail("missing \(e)", line: line)
    }

    func tap(_ e: XCUIElement, timeout: Double = 20, line: UInt = #line) {
        wait(e, timeout: timeout, line: line)
        e.tap()
    }

    func label(_ s: String) -> XCUIElement { app.buttons.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }

    func signIn() {
        let url = app.textFields["Server URL"]
        if url.waitForExistence(timeout: 5) {
            url.tap()
            url.typeText(env["ABS_URL"]!)
            tap(app.textFields["Username"])
            app.typeText(env["ABS_USER"]!)
            shot("01-sign-in")
            tap(app.secureTextFields["Password"])
            app.typeText(env["ABS_PASS"]!)
            tap(app.buttons["Sign in"])
            // the system offers to save the password
            for a in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] where a.buttons["Not Now"].waitForExistence(timeout: 5) {
                a.buttons["Not Now"].tap()
                break
            }
        }
    }

    func testTour() throws {
        continueAfterFailure = false
        app.launch()
        signIn()

        // library -> book page -> play
        tap(app.tabBars.buttons["Library"])
        wait(label("Alice"), timeout: 20)
        shot("03-library")
        tap(label("Alice"))
        let play = app.buttons.matching(NSPredicate(format: "label IN {'Play', 'Resume'}")).firstMatch
        wait(play, timeout: 20)
        shot("04-book")
        play.tap()
        sleep(4)

        // full player, playing
        tap(app.otherElements["mini"])
        wait(app.buttons["Pause"], timeout: 20)
        shot("05-player")
        app.buttons["Forward 30 seconds"].firstMatch.tap()
        app.swipeDown(velocity: .fast)

        // favorites: add, check, remove
        tap(app.buttons["Add to favorites"])
        tap(app.tabBars.buttons["Favorites"])
        wait(label("Alice"), timeout: 10)
        shot("09-favorites")
        tap(app.tabBars.buttons["Library"])
        tap(app.buttons["Remove from favorites"])

        tap(app.tabBars.buttons["Home"])
        wait(app.staticTexts["Continue listening"], timeout: 20)
        shot("02-home")

        tap(app.tabBars.buttons["Series"])
        wait(app.buttons.containing(NSPredicate(format: "label CONTAINS 'books'")).firstMatch, timeout: 20)
        shot("07-series")
        tap(app.buttons.containing(NSPredicate(format: "label CONTAINS 'books'")).firstMatch)
        shot("08-series-detail")

        // podcast library via the title menu
        tap(app.tabBars.buttons["Library"])
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to the grid
        tap(app.navigationBars.buttons["Audiobooks"])
        tap(app.buttons["Podcasts"])
        tap(label("Lex"))
        wait(app.staticTexts["Episodes"], timeout: 20)
        shot("06-podcast")

        // settings
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["Settings"])
        wait(app.staticTexts["Linked accounts"], timeout: 10)
        shot("10-settings")

        // download a small book, then see it under Settings -> Downloads
        tap(app.tabBars.buttons["Library"])
        app.tabBars.buttons["Library"].tap() // reselecting a tab pops to its root
        if app.navigationBars.buttons["Podcasts"].waitForExistence(timeout: 3) {
            app.navigationBars.buttons["Podcasts"].tap()
            tap(app.buttons["Audiobooks"])
        }
        tap(label("Velveteen"))
        tap(app.buttons["Download"])
        wait(app.buttons["Remove download"], timeout: 180)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["Settings"])
        tap(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Downloads'")).firstMatch)
        wait(label("Velveteen"))
        shot("11-downloads")

        // relaunch: the last title comes back paused in the mini player
        app.terminate()
        app.launch()
        wait(app.otherElements["mini"])
        wait(app.buttons["Play"])
        shot("12-restored")
    }

    /// Download progress, the downloads bar and list, cancelling, and a download carrying on after the app is killed.
    func testDownloads() throws {
        continueAfterFailure = false
        app.launch()
        signIn()
        // the dialog's button shares its label with the one that opened it
        func confirm(_ s: String) { tap(app.buttons.matching(identifier: s).element(boundBy: 1)) }

        // start clean, so the podcast's second episode (#501, 250 MB) is the second "Download" button
        tap(app.tabBars.buttons["Home"])
        tap(app.buttons["Settings"])
        tap(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Downloads'")).firstMatch)
        if app.buttons["Remove all"].waitForExistence(timeout: 3) {
            app.buttons["Remove all"].tap()
            confirm("Remove all")
        }
        tap(app.tabBars.buttons["Library"])
        app.tabBars.buttons["Library"].tap()
        if app.navigationBars.buttons["Audiobooks"].waitForExistence(timeout: 5) {
            app.navigationBars.buttons["Audiobooks"].tap()
            tap(app.buttons["Podcasts"])
        }
        tap(label("Lex"))
        let second = app.buttons.matching(identifier: "Download").element(boundBy: 1)
        tap(second)
        wait(app.buttons["dlbar"])
        sleep(1)
        shot("13-downloading")

        tap(app.buttons["dlbar"])
        wait(app.staticTexts["Downloading"])
        shot("14-queue")
        tap(app.buttons["Cancel download"])
        confirm("Cancel download")
        XCTAssert(app.staticTexts["Downloading"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["dlbar"].exists)

        // start again and kill the app mid-download: the system keeps the transfer going, and the app picks it up on launch
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(second)
        wait(app.buttons["dlbar"])
        app.terminate()
        app.launch()
        shot("15-after-relaunch")
        tap(app.tabBars.buttons["Library"])
        tap(label("Lex"))
        XCTAssert(app.buttons["Remove download"].waitForExistence(timeout: 300), "download didn't finish after the relaunch")
        shot("16-finished")
        XCTAssert(app.buttons["dlbar"].waitForNonExistence(timeout: 10))
    }
}
