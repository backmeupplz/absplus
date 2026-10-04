import XCTest

final class DownloadRetries: XCTestCase {
    func testQueueFailuresAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--download-retry-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Retry fixtures passed"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Waiting to retry…"].exists)
        app.terminate()
        app.launchArguments = ["--download-retry-test", "--retry-relaunch"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Relaunch passed"].waitForExistence(timeout: 20))
    }
}
