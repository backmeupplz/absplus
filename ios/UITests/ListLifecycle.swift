import XCTest

final class ListLifecycle: XCTestCase {
    func testListPositionSurvivesButtonAndGestureBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--list-lifecycle-test"]
        app.launch()
        let first = app.staticTexts["Title 000"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 { scroll.swipeUp() }
        // Pick a fully visible title, not a prefetched LazyVGrid accessibility node.
        let titles = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Title '"))
        let target = titles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < 700 }!
        let name = target.label
        XCTAssertNotEqual(name, "Title 000")
        let y = target.frame.minY
        for gesture in [false, true, false] {
            app.staticTexts[name].tap()
            XCTAssertTrue(app.staticTexts["Fixture details"].firstMatch.waitForExistence(timeout: 10))
            if gesture {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            } else {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
            // Wait through the delayed reload and cover/layout tasks, not just transition.
            sleep(2)
            XCTAssertTrue(app.staticTexts[name].isHittable)
            XCTAssertEqual(app.staticTexts[name].frame.minY, y, accuracy: 3)
        }
        // Search is part of this list context and must survive returning from details.
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Title 3")
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Title 300"].waitForExistence(timeout: 10))
        scroll.swipeUp()
        let filtered = titles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < 650 }!
        let filteredName = filtered.label
        let filteredY = filtered.frame.minY
        filtered.tap()
        XCTAssertTrue(app.staticTexts["Fixture details"].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        XCTAssertEqual(search.value as? String, "Title 3")
        XCTAssertEqual(app.staticTexts[filteredName].frame.minY, filteredY, accuracy: 3)
        app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'close'}")).firstMatch.tap()
        app.navigationBars.buttons["Fixture Library"].tap()
        app.buttons["Other Library"].tap()
        XCTAssertTrue(app.staticTexts["Other 000"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Other 000"].isHittable)
    }
}
