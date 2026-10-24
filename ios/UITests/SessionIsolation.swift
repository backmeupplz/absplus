import XCTest

final class SessionIsolation: XCTestCase {
    func testTransactionalTwoHostIsolation() {
        let app = XCUIApplication()
        app.launchArguments = ["--isolation-test"]
        app.launch()
        let result = app.staticTexts["isolation-result"]
        XCTAssertTrue(result.waitForLabel(timeout: 60) { $0 != "Running isolation checks" })
        XCTAssertEqual(result.label, "Isolation checks passed")
    }
}
