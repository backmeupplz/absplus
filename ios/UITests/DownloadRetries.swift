import XCTest

final class DownloadRetries: XCTestCase {
    func testInterruptedCompletionRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--download-retry-test", "--completion-seed"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Completion gap persisted"].waitForLabel(timeout: 15))
        app.terminate()
        app.launchArguments = ["--download-retry-test", "--completion-relaunch"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Interrupted completion passed"].waitForLabel(timeout: 15))
    }

    func testQueueFailuresAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--download-retry-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Retry fixtures passed"].waitForLabel(timeout: 45))
        XCTAssertTrue(app.staticTexts["Waiting to retry…"].exists)
        app.terminate()
        app.launchArguments = ["--download-retry-test", "--retry-relaunch"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Relaunch passed"].waitForLabel(timeout: 20))
    }
}
