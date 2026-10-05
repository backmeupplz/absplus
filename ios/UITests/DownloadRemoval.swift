import XCTest

final class DownloadRemoval: XCTestCase {
    func testSelectedRemovalCancellationAndOfflineRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--download-removal-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Removal seed passed"].waitForExistence(timeout: 20))
        app.terminate()
        app.launchArguments = ["--download-removal-test", "--removal-relaunch"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Removal relaunch passed"].waitForExistence(timeout: 20))
    }
}
