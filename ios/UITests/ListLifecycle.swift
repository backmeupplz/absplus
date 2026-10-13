import XCTest

final class ListLifecycle: XCTestCase {
    func testListPositionSurvivesButtonAndGestureBack() {
        continueAfterFailure = false
        // These waits are upper bounds, not sleeps. On a loaded CI simulator the app
        // stopped answering accessibility queries for ~10s after returning to this
        // large list; the recording showed the edge-swipe pop already finished, but
        // the one stalled query exhausted a 10s wait.
        let navigationTimeout: TimeInterval = 30
        let app = XCUIApplication()
        app.launchArguments = ["--list-lifecycle-test"]
        app.launch()
        let first = app.staticTexts["Title 000"]
        XCTAssertTrue(first.waitForExistence(timeout: navigationTimeout))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 { scroll.swipeUp() }
        // Pick a fully visible title, not a prefetched LazyVGrid accessibility node.
        let titles = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Title '"))
        let target = titles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < 700 }!
        let name = target.label
        XCTAssertNotEqual(name, "Title 000")
        let x = target.frame.minX
        let y = target.frame.minY
        for gesture in [false, true, false] {
            app.staticTexts[name].tap()
            XCTAssertTrue(app.staticTexts["Fixture details"].firstMatch.waitForExistence(timeout: navigationTimeout))
            if gesture {
                // CI recorded this fast drag starting then cancelling the pop,
                // with its final move and lift sharing a timestamp. Use a slower
                // edge drag and a distinct endpoint hold; still require a real pop.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.1,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
                let details = app.staticTexts["Fixture details"].firstMatch
                let popped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: details)
                XCTAssertEqual(XCTWaiter.wait(for: [popped], timeout: navigationTimeout), .completed, "Edge gesture did not pop details")
            } else {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: navigationTimeout))
            // Wait through the delayed reload and cover/layout tasks, not just transition.
            sleep(2)
            XCTAssertTrue(app.staticTexts[name].isHittable)
            XCTAssertEqual(app.staticTexts[name].frame.minY, y, accuracy: 3)
            // CI once recorded the grid drawn 16pt left after an edge-swipe pop; minY alone
            // can't see that, so require the anchor back in its column once the app responds.
            XCTAssertEqual(app.staticTexts[name].frame.minX, x, accuracy: 3, "List shifted sideways after returning")
        }
        // Search is part of this list context and must survive returning from details.
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Title 3")
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Title 300"].waitForExistence(timeout: navigationTimeout))
        scroll.swipeUp()
        let filtered = titles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < 650 }!
        let filteredName = filtered.label
        let filteredX = filtered.frame.minX
        let filteredY = filtered.frame.minY
        filtered.tap()
        XCTAssertTrue(app.staticTexts["Fixture details"].firstMatch.waitForExistence(timeout: navigationTimeout))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        XCTAssertEqual(search.value as? String, "Title 3")
        XCTAssertEqual(app.staticTexts[filteredName].frame.minY, filteredY, accuracy: 3)
        XCTAssertEqual(app.staticTexts[filteredName].frame.minX, filteredX, accuracy: 3, "Filtered list shifted sideways after returning")
        app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'close'}")).firstMatch.tap()
        app.navigationBars.buttons["Fixture Library"].tap()
        app.buttons["Other Library"].tap()
        XCTAssertTrue(app.staticTexts["Other 000"].waitForExistence(timeout: navigationTimeout))
        XCTAssertTrue(app.staticTexts["Other 000"].isHittable)
    }
}
