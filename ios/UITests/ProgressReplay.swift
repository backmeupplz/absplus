import XCTest

final class ProgressReplay: XCTestCase {
    func testProcessRelaunchUploadsWithoutPlaying() {
        let app = XCUIApplication()
        for phase in ["seed", "drain"] {
            app.launchArguments = ["--progress-test", "--progress-" + phase]
            app.launch()
            let result = app.staticTexts["progress-result"]
            XCTAssertTrue(result.waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "label BEGINSWITH 'PASS' OR label BEGINSWITH 'FAIL'"), evaluatedWith: result)
            waitForExpectations(timeout: 30)
            XCTAssertEqual(result.label, phase == "seed" ? "PASS seeded" : "PASS relaunched")
            app.terminate()
        }
    }

    func testDurableProgressIntegration() {
        let app = XCUIApplication()
        app.launchArguments = ["--progress-test"]
        app.launch()
        let result = app.staticTexts["progress-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let done = NSPredicate(format: "label BEGINSWITH 'PASS' OR label BEGINSWITH 'FAIL'")
        expectation(for: done, evaluatedWith: result)
        waitForExpectations(timeout: 60)
        XCTAssertEqual(result.label, "PASS progress replay")
    }
}
