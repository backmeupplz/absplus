import XCTest

final class RetainedDownloads: XCTestCase {
    func testRetainedMediaAfterLogoutAndOnlineLogin() {
        let app = XCUIApplication()
        app.launchArguments = ["--retained-test"]
        app.launch()
        let result = app.staticTexts["retained-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let done = NSPredicate(format: "label != %@", "Running retained checks")
        expectation(for: done, evaluatedWith: result)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(result.label, "Retained checks passed")
    }
}
