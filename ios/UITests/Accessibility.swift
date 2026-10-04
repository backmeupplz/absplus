import XCTest

final class Accessibility: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--accessibility-test"]
        app.launch()
        return app
    }

    func testAboutLinksAndUnlinkAction() {
        let app = launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Unlink Reader"].waitForExistence(timeout: 10))
        app.swipeUp()
        for (label, url) in [("Website", "https://absplus.app"),
                             ("Source code", "https://github.com/backmeupplz/absplus"),
                             ("Privacy policy", "https://absplus.app/privacy/")] {
            app.links[label].tap()
            XCTAssertTrue(app.staticTexts[url].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label MATCHES %@ OR value MATCHES %@",
            ".*[0-9]+[.][0-9]+[.][0-9]+.*", ".*[0-9]+[.][0-9]+[.][0-9]+.*"
        )).firstMatch.exists)
    }

    func testFavoriteActionReflectsBothStatesAndShareHasAName() {
        let app = launch()
        app.buttons["Details"].tap()
        let add = app.buttons["Add to favorites"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share progress"].exists)
        add.tap()
        let remove = app.buttons["Remove from favorites"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    func testBothPlayersExposeCurrentActionAndSkipNames() {
        let app = launch()
        app.buttons["Player"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Play").count, 2)
        XCTAssertTrue(app.buttons["Back 30 seconds"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Forward 30 seconds").count, 2)
        XCTAssertTrue(app.buttons["Playback speed 1"].exists)
        app.buttons["Change fixture playback state"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Pause").count, 2)
        XCTAssertEqual(app.buttons.matching(identifier: "Play").count, 0)
        app.buttons["Change fixture playback state"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Play").count, 2)
    }
}
