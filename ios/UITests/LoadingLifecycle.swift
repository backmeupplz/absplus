import XCTest

final class LoadingLifecycle: XCTestCase {
    private func launch(_ flags: String...) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loading-test"] + flags
        app.launch()
        return app
    }
    private func initial(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["loading.initial"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertFalse(app.staticTexts["No titles"].exists)
        XCTAssertFalse(app.staticTexts["No favorites"].exists)
        XCTAssertFalse(app.staticTexts["No series"].exists)
    }
    private func release(_ app: XCUIApplication) { app.buttons["Release fixture requests"].tap() }
    private func retry(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["loading.retry"].waitForExistence(timeout: 15))
        app.buttons["loading.retry"].tap()
    }
    private func hold(_ app: XCUIApplication) { app.buttons["Hold fixture requests"].tap() }
    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.isHittable, app.debugDescription)
        // Hosted iOS 26 can animate the 50ms synthesized tap without committing
        // selection. Send one deliberate touch, then prove navigation before
        // attributing a missing loading state to the destination screen.
        button.press(forDuration: 0.1)
        XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: 4), app.debugDescription)
    }

    func testDelayedSuccessAllTabsAndDetailsBack() {
        let app = launch()
        initial(app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Home initial loading"; shot.lifetime = .keepAlways; add(shot)
        release(app)
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 10))
        hold(app)
        tab(app, "Library")
        initial(app)
        release(app)
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 10))
        hold(app)
        app.staticTexts["Loaded title"].tap()
        initial(app)
        // Leave before details finish; cancelled work must not replace the retained list.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 5))
        release(app)
        app.staticTexts["Loaded title"].tap()
        XCTAssertTrue(app.staticTexts["Loaded details"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 5))
        hold(app)
        tab(app, "Series")
        initial(app)
        release(app)
        XCTAssertTrue(app.staticTexts["Loaded series"].firstMatch.waitForExistence(timeout: 12))
        tab(app, "Favorites")
        XCTAssertTrue(app.staticTexts["Loaded details"].waitForExistence(timeout: 12), app.debugDescription)
        app.staticTexts["Loaded details"].tap()
        XCTAssertTrue(app.buttons["Remove from favorites"].waitForExistence(timeout: 10))
    }

    func testFailureRetryAndRepeatedNavigation() {
        let app = launch("--failure")
        initial(app)
        release(app)
        retry(app)
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 12))
        tab(app, "Library")
        retry(app)
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 12))
        app.staticTexts["Loaded title"].tap()
        retry(app)
        XCTAssertTrue(app.staticTexts["Loaded details"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tab(app, "Series")
        retry(app)
        XCTAssertTrue(app.staticTexts["Loaded series"].firstMatch.waitForExistence(timeout: 12))
        tab(app, "Favorites")
        retry(app)
        XCTAssertTrue(app.staticTexts["Loaded details"].waitForExistence(timeout: 12), app.debugDescription)
    }

    func testEmptyOnlyAfterSuccess() {
        let app = launch("--empty")
        initial(app)
        release(app)
        XCTAssertTrue(app.staticTexts["Nothing played yet"].waitForExistence(timeout: 12))
        hold(app)
        tab(app, "Library")
        initial(app)
        release(app)
        XCTAssertTrue(app.staticTexts["No titles"].waitForExistence(timeout: 12))
        hold(app)
        tab(app, "Series")
        initial(app)
        release(app)
        XCTAssertTrue(app.staticTexts["No series"].waitForExistence(timeout: 12))
        hold(app)
        tab(app, "Favorites")
        initial(app)
        release(app)
        XCTAssertTrue(app.staticTexts["No favorites"].waitForExistence(timeout: 10))
    }

    func testCacheRefreshFailureKeepsTitlesAndSwitchResets() {
        let app = launch("--cached", "--failure")
        tab(app, "Library")
        XCTAssertTrue(app.staticTexts["Cached title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["loading.refresh"].exists)
        release(app)
        XCTAssertTrue(app.buttons["loading.retry"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Cached title"].exists)
        retry(app)
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 10))
        hold(app)
        app.navigationBars.buttons["Fixture Library"].firstMatch.tap()
        app.buttons["Other Library"].firstMatch.tap()
        initial(app)
        release(app)
        XCTAssertFalse(app.staticTexts["Loaded title"].exists)
        retry(app)
        XCTAssertTrue(app.staticTexts["Other title"].waitForExistence(timeout: 12))
    }

    func testOfflineIsNotEmptyAndRetrySettles() {
        let app = launch("--offline")
        initial(app)
        release(app)
        XCTAssertTrue(app.buttons["loading.retry"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Offline"].exists)
        XCTAssertFalse(app.staticTexts["Nothing played yet"].exists)
        retry(app)
        XCTAssertTrue(app.buttons["loading.retry"].waitForExistence(timeout: 12))
        tab(app, "Library")
        XCTAssertTrue(app.buttons["loading.retry"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["No titles"].exists)
    }

    func testRapidLibrarySwitchRejectsStaleResponse() {
        let app = launch()
        tab(app, "Library")
        initial(app)
        app.navigationBars.buttons["Fixture Library"].firstMatch.tap()
        app.buttons["Other Library"].firstMatch.tap()
        release(app)
        XCTAssertTrue(app.staticTexts["Other title"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["Loaded title"].exists)
        app.navigationBars.buttons["Other Library"].firstMatch.tap()
        app.buttons["Fixture Library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Loaded title"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["Other title"].exists)
    }

    func testLoginFailureRetainsInputAndAllowsRetry() {
        let app = launch("--login", "--failure")
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("fixture-user")
        let signIn = app.buttons["Sign in"]
        signIn.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Signing in"].firstMatch.waitForExistence(timeout: 2))
        release(app)
        XCTAssertTrue(app.staticTexts["login.error"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Username"].value as? String, "fixture-user")
        XCTAssertTrue(signIn.isEnabled)
    }

    func testLinkAccountLoadingCancelAndRetry() {
        let app = launch("--failure")
        app.buttons["Settings"].tap()
        app.buttons["Link account"].tap()
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("fixture-user")
        app.buttons["Link"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Linking account"].firstMatch.waitForExistence(timeout: 2))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Link account"].waitForExistence(timeout: 5))
        app.buttons["Link account"].tap()
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Linked fixture-user"].exists)
    }
    func testNoLibrariesFinishesRatherThanSpinningForever() {
        let app = launch("--no-libraries", "--empty")
        tab(app, "Library")
        release(app)
        XCTAssertTrue(app.staticTexts["No titles"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.descendants(matching: .any)["loading.initial"].exists)
    }
}
