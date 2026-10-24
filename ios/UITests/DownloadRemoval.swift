import XCTest

final class DownloadRemoval: XCTestCase {
    func testSelectedRemovalCancellationAndOfflineRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--download-removal-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Removal seed passed"].waitForLabel(timeout: 20))
        app.terminate()
        app.launchArguments = ["--download-removal-test", "--removal-relaunch"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Removal relaunch passed"].waitForLabel(timeout: 20))
    }
}
