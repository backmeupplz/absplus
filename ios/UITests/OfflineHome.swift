import XCTest

final class OfflineHome: XCTestCase {
    func testExactEpisodeFilteringAndLiveDownloadChanges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--offline-home-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Episode saved"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Complete book"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Episode recent"].exists)
        app.buttons["Save recent"].tap()
        let recent = app.staticTexts.matching(identifier: "Episode recent")
        XCTAssertTrue(recent.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(recent.count, 2, "Both continue and history should show the newly saved episode")
        app.buttons["Remove recent"].tap()
        XCTAssertTrue(recent.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Episode saved"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Complete book").count, 2)
        app.buttons["Save recent"].tap()
        XCTAssertTrue(recent.firstMatch.waitForExistence(timeout: 5))
        // Open the history navigation link, not the continue tile that starts playback.
        app.descendants(matching: .any)["history-home-podcast/recent"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Home"].waitForExistence(timeout: 5))
        app.buttons["Remove recent"].tap()
        app.navigationBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Episode saved"].waitForExistence(timeout: 5))
        XCTAssertFalse(recent.firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Complete book").count, 2)
    }
}
