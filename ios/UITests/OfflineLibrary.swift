import XCTest

final class OfflineLibrary: XCTestCase {
    func testMembershipStorageAndLiveCompletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--offline-library-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Downloaded"].waitForExistence(timeout: 15))
        let search = app.searchFields.firstMatch
        func query(_ text: String) {
            search.tap()
            let clear = search.buttons["Clear text"]
            if clear.exists { clear.tap() }
            search.typeText(text)
            app.keyboards.buttons["Search"].tap()
            XCTAssertEqual(search.value as? String, text)
        }
        query("Fixture complete")
        XCTAssertTrue(app.staticTexts["Fixture complete"].waitForExistence(timeout: 5))
        query("Fixture podcast")
        XCTAssertTrue(app.staticTexts["Fixture podcast"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture podcast-zero"].exists)
        app.buttons["Remove episode"].tap()
        XCTAssertTrue(app.staticTexts["Fixture podcast"].waitForNonExistence(timeout: 5))
        for id in ["partial", "zero", "empty", "missing-zero"] {
            query("Fixture " + id)
            XCTAssertFalse(app.staticTexts["Fixture " + id].exists)
        }
        query("Fixture partial")
        app.buttons["Complete partial"].tap()
        XCTAssertTrue(app.staticTexts["Fixture partial"].waitForExistence(timeout: 5))
        app.buttons["Undo partial"].tap()
        XCTAssertTrue(app.staticTexts["Fixture partial"].waitForNonExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'close'}")).firstMatch.tap()
        app.buttons["Settings"].tap()
        app.staticTexts["Downloads"].firstMatch.tap()
        let partial = app.staticTexts["Fixture partial"]
        let row = app.cells.containing(.staticText, identifier: "Fixture partial").firstMatch
        for _ in 0..<40 {
            if partial.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(partial.isHittable, "Partial title remains manageable in Storage")
        // The loop stops as soon as the row peeks in, often at the bottom edge by
        // the home indicator. Center it with a held drag that leaves no momentum.
        let lift = row.frame.midY - app.windows.firstMatch.frame.midY
        if lift > 0 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.1,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: -lift)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        // A swipe that lands on a still-decelerating list only stops the scroll,
        // so wait for the row to settle before revealing its swipe action.
        var frame = row.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if row.frame == frame { break }
            frame = row.frame
        }
        XCTAssertTrue(row.isHittable, "Partial row settled on screen")
        let remove = app.buttons["Remove"].firstMatch
        for _ in 0..<3 where !remove.exists {
            // A deliberate partial drag across the whole row reveals the action
            // without a full swipe, which would delete it without a tap.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            _ = remove.waitForExistence(timeout: 2)
            XCTAssertTrue(app.navigationBars["Downloads"].exists, "Swipe must stay in Storage, not open details")
        }
        XCTAssertTrue(remove.isHittable, "Swipe reveals the Remove action")
        XCTAssertEqual(remove.frame.midY, row.frame.midY, accuracy: 4, "Remove belongs to the partial row")
        remove.tap()
        XCTAssertTrue(partial.waitForNonExistence(timeout: 5))
    }

    func testLiveMutationAndDetailReturnKeepVisibleAnchor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--offline-library-test"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Downloaded"].waitForExistence(timeout: 15))
        let scroll = app.scrollViews.firstMatch
        let retry = app.buttons["loading.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(retry.frame.maxY, scroll.frame.minY, "Retained error must sit outside the scroll viewport")
        for _ in 0..<5 { scroll.swipeUp() }
        let titles = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fixture anchor-'"))
        let target = titles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < 650 }!
        let name = target.label, y = target.frame.minY
        app.buttons["Complete partial"].tap()
        XCTAssertEqual(app.staticTexts[name].frame.minY, y, accuracy: 3)
        XCTAssertTrue(app.staticTexts[name].isHittable, "Live insertion must not hide the retained anchor behind refresh feedback")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Downloaded anchor after live insertion"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Tap the observed point: XCTest element.tap() may silently scroll an
        // occluded title into view, invalidating the saved viewport baseline.
        app.staticTexts[name].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars.buttons["Downloaded"].waitForExistence(timeout: 5))
        app.buttons["Undo partial"].tap()
        app.navigationBars.buttons["Downloaded"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[name].isHittable)
        XCTAssertEqual(app.staticTexts[name].frame.minY, y, accuracy: 3)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.staticTexts[name].frame.minY, y, accuracy: 3)
    }
}
