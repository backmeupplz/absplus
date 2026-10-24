import XCTest

final class ProgressReplay: XCTestCase {
    func verdict(_ label: String) -> Bool { label.hasPrefix("PASS") || label.hasPrefix("FAIL") }

    func testProcessRelaunchUploadsWithoutPlaying() {
        let app = XCUIApplication()
        for phase in ["seed", "drain"] {
            app.launchArguments = ["--progress-test", "--progress-" + phase]
            app.launch()
            let result = app.staticTexts["progress-result"]
            XCTAssertTrue(result.waitForLabel(timeout: 45, verdict))
            XCTAssertEqual(result.label, phase == "seed" ? "PASS seeded" : "PASS relaunched")
            app.terminate()
        }
    }

    func testPlaybackAuthenticationFailureAndQueueOwnership() {
        let app = XCUIApplication()
        app.launchArguments = ["--progress-test", "--progress-playback-auth"]
        app.launch()
        let result = app.staticTexts["progress-result"]
        XCTAssertTrue(result.waitForLabel(timeout: 45, verdict))
        XCTAssertEqual(result.label, "PASS playback authentication")
    }

    func testDurableProgressIntegration() {
        let app = XCUIApplication()
        app.launchArguments = ["--progress-test"]
        app.launch()
        let result = app.staticTexts["progress-result"]
        XCTAssertTrue(result.waitForLabel(timeout: 75, verdict))
        XCTAssertEqual(result.label, "PASS progress replay")
    }
}
