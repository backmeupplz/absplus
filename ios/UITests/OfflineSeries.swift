import XCTest

final class OfflineSeries: XCTestCase {
    private func launchShelf() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--offline-series-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Cached series"].waitForExistence(timeout: 15))
        // The failed refresh must leave cached rows usable, not just visible to AX.
        XCTAssertTrue(app.buttons["loading.retry"].waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(app.buttons["loading.retry"].frame.maxY, app.staticTexts["Cached series"].frame.minY)
        app.staticTexts["Cached series"].tap()
        XCTAssertTrue(app.staticTexts["Series title 006"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    func testInitiallyUnavailableTitlesRejoinRetainedRoster() {
        let app = launchShelf()
        let missing = app.staticTexts["Series title 000"]
        XCTAssertFalse(missing.exists)
        app.buttons["Go online"].tap()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        app.buttons["Go offline"].tap()
        XCTAssertTrue(missing.waitForNonExistence(timeout: 5))
        app.buttons["Insert ahead"].tap()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        app.buttons["Remove ahead"].tap()
        XCTAssertTrue(missing.waitForNonExistence(timeout: 5))
    }

    func testDetailRemovalAndRepeatedChangesPreserveSurvivingPixelAnchor() {
        let app = launchShelf()
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<8 { scroll.swipeUp() }
        // Deliberately stop between rows, rather than at a scroll target boundary.
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        let titles = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Series title '"))
        let visible = titles.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY > 160 && $0.frame.maxY < 650 }
        XCTAssertGreaterThan(visible.count, 3)
        let anchor = visible[0].label
        let y = visible[0].frame.minY
        let removed = visible.last!.label
        XCTAssertNotEqual(anchor, removed)
        XCTAssertGreaterThan(Int(anchor.suffix(3))!, 30)

        func checkAnchor() {
            XCTAssertTrue(app.staticTexts[anchor].waitForExistence(timeout: 5))
            // Check immediately after navigation/update and again after layout settles.
            XCTAssertTrue(app.staticTexts[anchor].isHittable)
            XCTAssertEqual(app.staticTexts[anchor].frame.minY, y, accuracy: 3)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(app.staticTexts[anchor].frame.minY, y, accuracy: 3)
        }
        func back(_ gesture: Bool = false) {
            if gesture {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        }

        app.staticTexts[removed].tap()
        XCTAssertTrue(app.buttons["Remove download"].waitForExistence(timeout: 5))
        app.buttons["Remove download"].tap()
        let confirmation = app.sheets.buttons["Remove download"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        // Hosted iOS 26 has animated the 50ms confirmation tap without committing
        // it: five seconds later the dialog was still up and the detail still
        // offered "Remove download" (#99). Send a deliberate press, and press
        // again only while the dialog is still showing, so a committed removal
        // that is just slow to redraw is never confirmed twice.
        let download = app.buttons["Download"]
        for _ in 0..<3 where !download.exists {
            if confirmation.exists { confirmation.press(forDuration: 0.1) }
            _ = download.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(download.exists, app.debugDescription)
        app.buttons["Notify twice"].tap()
        back()
        checkAnchor()
        XCTAssertFalse(app.staticTexts[removed].exists)

        // Multiple callbacks before a layout, both visible and while real detail is open.
        for hidden in [false, true] {
            for action in ["Insert ahead", "Remove ahead", "Go online", "Go offline", "Notify twice"] {
                if hidden {
                    app.staticTexts[anchor].tap()
                    XCTAssertTrue(app.buttons["Remove download"].waitForExistence(timeout: 5))
                }
                app.buttons[action].tap()
                app.buttons["Notify twice"].tap()
                if hidden { back(action == "Remove ahead") }
                checkAnchor()
                if action == "Go online" { XCTAssertTrue(app.staticTexts[removed].exists) }
                if action == "Go offline" { XCTAssertFalse(app.staticTexts[removed].exists) }
            }
        }
    }
}
