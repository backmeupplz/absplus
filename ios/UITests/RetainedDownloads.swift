import XCTest

final class RetainedDownloads: XCTestCase {
    func testRetainedMediaAfterLogoutAndOnlineLogin() {
        let app = XCUIApplication()
        app.launchArguments = ["--retained-test"]
        app.launch()
        let result = app.staticTexts["retained-result"]
        XCTAssertTrue(result.waitForLabel(timeout: 45) { $0 != "Running retained checks" })
        XCTAssertEqual(result.label, "Retained checks passed")
    }
}
