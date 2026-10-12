import XCTest
import UIKit

/// Real production views, URLSession metadata/positions and AVQueuePlayer with a
/// local silent WAV. Gates make Back/switching deterministic without real media.
final class PlaybackPreparation: XCTestCase, FixtureGates {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loading-test", "--playback"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Release fixture requests"].waitForExistence(timeout: gateTimeout), app.debugDescription)
        release(app)
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 12))
        return app
    }

    private func state(_ app: XCUIApplication, _ text: String) {
        let matches = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: app.staticTexts["fixture.playback"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, app.debugDescription)
    }

    /// Fixture counters only refresh on Check: press deliberately, then wait for
    /// the expected text instead of reading it once while the touch may still be
    /// in flight. A readout that already shows the expected text passes at once.
    private func check(_ app: XCUIApplication, _ button: String, _ readout: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons[button].press(forDuration: 0.1)
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: app.staticTexts[readout])
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: gateTimeout), .completed, app.debugDescription, file: file, line: line)
    }

    private func library(_ app: XCUIApplication) {
        tab(app, "Library")
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
        release(app)
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
            check(app, "Check positions", "fixture.positions", "Position requests: \(attempt)")
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
        hold(app)
        app.staticTexts["Loaded title"].firstMatch.tap()
        state(app, "preparing: first")
        tab(app, "Library")
        // Library itself also waits for the held metadata; leave it visible while releasing.
        releaseAndAssertNoPlayback(app)
        tab(app, "Home")
        XCTAssertTrue(app.staticTexts["Other title"].waitForExistence(timeout: 12))
        hold(app)
        app.buttons["continue.other"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["context.play.other"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["context.play.other"].tap()
        state(app, "preparing: other")
        tab(app, "Library")
        releaseAndAssertNoPlayback(app)
    }

    func testRecentPlayButtonCancelsMetadataOnSettingsNavigation() {
        let app = launch()
        hold(app)
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
        XCTAssertTrue(app.buttons["Release fixture requests"].waitForExistence(timeout: gateTimeout), app.debugDescription)
        release(app)
        for _ in 0..<2 {
            tab(app, "Favorites")
            XCTAssertTrue(app.staticTexts["Known favorite"].waitForExistence(timeout: 8))
            sleep(4)
            check(app, "Check favorite requests", "fixture.favorites", "Favorite metadata requests: 0")
            tab(app, "Home")
        }
    }
    func testHomeShelfScrollsToFifthAndMenusStayWithTheirTiles() {
        let app = launch()
        let firstX = app.buttons["continue.first"].frame.minX
        app.buttons["continue.other"].swipeLeft()
        XCTAssertTrue(app.buttons["continue.fifth"].isHittable, "Five-card shelf must scroll horizontally")
        XCTAssertLessThan(app.buttons["continue.first"].frame.minX, firstX)
        app.buttons["continue.fourth"].swipeRight()
        XCTAssertTrue(app.buttons["continue.first"].isHittable)
        app.buttons["continue.other"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["context.play.other"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["context.play.first"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)).tap()
        app.buttons["continue.first"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["context.play.first"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["context.play.other"].exists)
        app.buttons["Details"].tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Loaded title"].exists)
        XCTAssertFalse(app.staticTexts["Other title"].exists)
    }

    func testHomePointerMenuDoesNotReuseLastTouchedTile() throws {
        // XCTest rejects pointer events on iPhone; keep this runnable on iPad.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Pointer events require an iPad simulator; physical keyboard/VoiceOver remain manual coverage.")
        let app = launch()
        app.buttons["continue.other"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["context.play.other"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)).tap()
        app.buttons["continue.first"].rightClick()
        XCTAssertTrue(app.buttons["context.play.first"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["context.play.other"].exists)
    }

    func testHomePlayRetriesWrongSchemaWithoutCachingIt() {
        let app = launch(["--invalid-item-response"])
        app.buttons["Release positions"].tap()
        app.buttons["continue.first"].tap()
        state(app, "preparing: first")
        state(app, "Current: none; preparing: none; playing: false")
        check(app, "Check metadata", "fixture.metadata", "Metadata requests: 1; cache: absent")
        app.buttons["continue.first"].tap()
        state(app, "Current: first; preparing: none; playing: true")
        check(app, "Check metadata", "fixture.metadata", "Metadata requests: 2; cache: valid")
    }

    func testHomePlayRefetchesInvalidExistingItemCache() {
        let app = launch(["--invalid-item-cache"])
        check(app, "Check metadata", "fixture.metadata", "Metadata requests: 0; cache: invalid")
        app.buttons["Release positions"].tap()
        app.buttons["continue.first"].tap()
        state(app, "Current: first; preparing: none; playing: true")
        check(app, "Check metadata", "fixture.metadata", "Metadata requests: 1; cache: valid")
    }

    func testHomeSwitchDuringMetadataStartsOnlyLatestTitle() {
        let app = launch()
        hold(app)
        app.buttons["continue.first"].tap()
        state(app, "preparing: first")
        app.buttons["continue.other"].tap()
        state(app, "preparing: other")
        release(app)
        app.buttons["Release positions"].tap()
        state(app, "Current: other; preparing: none; playing: true")
        sleep(4)
        state(app, "Current: other; preparing: none; playing: true")
    }
}
