import XCTest

// Temporary experiment for #98; not for merge.
final class ListExp98: XCTestCase {
    func testLeadingAnchoredRestorePadding() { run(margins: false) }
    func testLeadingAnchoredRestoreMargins() { run(margins: true) }

    private func run(margins: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--list-lifecycle-test"]
        app.launchEnvironment["ABS98_EXP"] = "1"
        if margins { app.launchEnvironment["ABS98_MARGINS"] = "1" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Title 000"].waitForExistence(timeout: 30))
        let x0 = app.staticTexts["Title 000"].frame.minX
        print("EXP98 margins=\(margins) before x000=\(x0)")
        sleep(9)
        let e = app.staticTexts["Title 150"]
        let x = e.exists ? e.frame.minX : -1
        print("EXP98 margins=\(margins) Title 150 exists=\(e.exists) x=\(x) y=\(e.exists ? e.frame.minY : -1) x151=\(app.staticTexts["Title 151"].frame.minX)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "exp-\(margins)"; shot.lifetime = .keepAlways; add(shot)
        app.scrollViews.firstMatch.swipeUp()
        sleep(3)
        let vis = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Title '")).allElementsBoundByIndex.first { $0.isHittable }
        print("EXP98 margins=\(margins) after swipe first=\(vis?.label ?? "-") x=\(vis?.frame.minX ?? -1)")
        XCTAssertEqual(x0, 16, accuracy: 1, "EXP98 margins=\(margins) initial x=\(x0)")
        XCTAssertEqual(x, 16, accuracy: 1, "EXP98 margins=\(margins) after leading-anchored scroll x=\(x)")
    }
}
