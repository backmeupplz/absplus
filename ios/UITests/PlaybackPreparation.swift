import XCTest

/// Real production views, URLSession metadata/positions and AVQueuePlayer with a
/// local silent WAV. Gates make Back/switching deterministic without real media.
final class PlaybackPreparation: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loading-test", "--playback"]
        app.launch()
        app.buttons["Release fixture requests"].tap()
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 12))
        return app
    }

    private func state(_ app: XCUIApplication, _ text: String) {
        let matches = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: app.staticTexts["fixture.playback"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, app.debugDescription)
    }

    private func library(_ app: XCUIApplication) {
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 12))
    }

    private func open(_ app: XCUIApplication, _ title: String) {
        app.staticTexts[title].firstMatch.tap()
        // Nonempty tracks are required: the real Play control must be enabled.
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Play"].firstMatch.isEnabled)
    }

    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }

    private func releaseAndAssertNoPlayback(_ app: XCUIApplication) {
        app.buttons["Release fixture requests"].tap()
        app.buttons["Release positions"].tap()
        // Beyond both synthetic metadata and position delays; cancellation must
        // remain terminal even if work would otherwise finish after leaving.
        sleep(6)
        state(app, "Current: none; preparing: none; playing: false")
        XCTAssertFalse(app.descendants(matching: .any)["mini"].exists)
    }

    func testDetailBackCancelsPositionsAndRepeatedOpenCanPlayNewTitle() {
        let app = launch()
        library(app)
        for attempt in 1...2 {
            app.buttons["Hold positions"].tap()
            open(app, "Loaded title")
            app.buttons["Play"].firstMatch.doubleTap()
            state(app, "preparing: first")
            app.buttons["Check positions"].tap()
            XCTAssertEqual(app.staticTexts["fixture.positions"].label, "Position requests: \(attempt)")
            back(app)
            releaseAndAssertNoPlayback(app)
        }
        app.buttons["Hold positions"].tap()
        open(app, "Other title")
        app.buttons["Play"].firstMatch.tap()
        state(app, "preparing: other")
        app.buttons["Release positions"].tap()
        state(app, "Current: other; preparing: none; playing: true")
        XCTAssertTrue(app.descendants(matching: .any)["mini"].exists)
        back(app)
        state(app, "Current: other; preparing: none; playing: true")
        // Cancelling another preparation must not pause or clear the existing audio.
        app.buttons["Hold positions"].tap()
        open(app, "Loaded title")
        app.buttons["Play"].firstMatch.tap()
        state(app, "preparing: first")
        back(app)
        app.buttons["Release positions"].tap()
        sleep(4)
        state(app, "Current: other; preparing: none; playing: true")
    }

    func testHomeTileMetadataAndContextMenuCancelWhenLeavingHome() {
        let app = launch()
        app.buttons["Hold fixture requests"].tap()
        app.staticTexts["Loaded title"].firstMatch.tap()
        state(app, "preparing: first")
        app.tabBars.buttons["Library"].tap()
        // Library itself also waits for the held metadata; leave it visible while releasing.
        releaseAndAssertNoPlayback(app)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Other title"].waitForExistence(timeout: 12))
        app.buttons["Hold fixture requests"].tap()
        app.buttons["continue.other"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["context.play.other"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["context.play.other"].tap()
        state(app, "preparing: other")
        app.tabBars.buttons["Library"].tap()
        releaseAndAssertNoPlayback(app)
    }

    func testRecentPlayButtonCancelsMetadataOnSettingsNavigation() {
        let app = launch()
        app.buttons["Hold fixture requests"].tap()
        app.buttons["Play"].firstMatch.tap()
        state(app, "preparing: other")
        app.buttons["Settings"].tap()
        releaseAndAssertNoPlayback(app)
    }

    func testEpisodeButtonAndRowCancelPositionsOnBack() {
        let app = launch()
        library(app)
        for button in [true, false] {
            app.buttons["Hold positions"].tap()
            open(app, "Podcast title")
            if button { app.buttons["Play"].firstMatch.tap() }
            else { app.staticTexts["Fixture episode"].tap() }
            state(app, "preparing: podcast/episode")
            back(app)
            releaseAndAssertNoPlayback(app)
        }
    }
    func testPopulatedFavoritesDoNotRefetchEveryTitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loading-test", "--populated-favorites"]
        app.launch()
        app.buttons["Release fixture requests"].tap()
        for _ in 0..<2 {
            app.tabBars.buttons["Favorites"].tap()
            XCTAssertTrue(app.staticTexts["Known favorite"].waitForExistence(timeout: 8))
            sleep(4)
            app.buttons["Check favorite requests"].tap()
            XCTAssertEqual(app.staticTexts["fixture.favorites"].label, "Favorite metadata requests: 0")
            app.tabBars.buttons["Home"].tap()
        }
    }
    func testHomeSwitchDuringMetadataStartsOnlyLatestTitle() {
        let app = launch()
        app.buttons["Hold fixture requests"].tap()
        app.buttons["continue.first"].tap()
        state(app, "preparing: first")
        app.buttons["continue.other"].tap()
        state(app, "preparing: other")
        app.buttons["Release fixture requests"].tap()
        app.buttons["Release positions"].tap()
        state(app, "Current: other; preparing: none; playing: true")
        sleep(4)
        state(app, "Current: other; preparing: none; playing: true")
    }
}
