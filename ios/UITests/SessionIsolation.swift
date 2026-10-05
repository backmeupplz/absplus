import XCTest

final class SessionIsolation: XCTestCase {
    func testTransactionalTwoHostIsolation() {
        let app = XCUIApplication()
        app.launchArguments = ["--isolation-test"]
        app.launch()
        let result = app.staticTexts["isolation-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label != %@", "Running isolation checks"), evaluatedWith: result)
        waitForExpectations(timeout: 45)
        XCTAssertEqual(result.label, "Isolation checks passed")
    }
}
