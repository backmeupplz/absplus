import XCTest

/// Acknowledged touches for the `--loading-test` fixture. Suites that drive its
/// request gates and tab bar opt in, so other suites keep these names free.
protocol FixtureGates {}

extension FixtureGates where Self: XCTestCase {
    // Hosted CI simulators can spend ~3s on one accessibility snapshot while the
    // app is busy. With the first read ~1s in, a 4s budget allowed only one read,
    // which ended past the deadline even though the gate had already flipped.
    // Waits for states the fixture holds until the test acts still require that
    // state; they just allow several reads of it.
    var gateTimeout: TimeInterval { 15 }

    func release(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        gate(app, "Release fixture requests", "released", file: file, line: line)
    }
    func hold(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        gate(app, "Hold fixture requests", "held", file: file, line: line)
    }
    private func gate(_ app: XCUIApplication, _ name: String, _ value: String, file: StaticString, line: UInt) {
        let button = app.buttons[name]
        XCTAssertTrue(button.isHittable, app.debugDescription, file: file, line: line)
        // Like tab selection, a highlighted 50ms touch is not an acknowledgment.
        // Hosted CI has also dropped the 0.1s press outright: every read for the
        // whole budget stayed at the old value (#82). Both buttons only set the
        // flag to a fixed value, so pressing again after an unacknowledged
        // attempt cannot fire anything twice. The waits total gateTimeout (each
        // press adds its own snapshot time); the fixture keeps held requests
        // past the app's 20s URLRequest timeout, so a slow press still finds
        // them held rather than failed (#82).
        let attempts = 3
        var result = XCTWaiter.Result.timedOut
        for _ in 1...attempts where result != .completed {
            button.press(forDuration: 0.1)
            let gate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: button)
            result = XCTWaiter.wait(for: [gate], timeout: gateTimeout / Double(attempts))
        }
        // A window can end inside a slow snapshot after the value flipped; the
        // last read has no deadline, so only a value that never flipped fails.
        XCTAssertTrue(result == .completed || button.value as? String == value, app.debugDescription, file: file, line: line)
    }
    func tab(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.isHittable, app.debugDescription, file: file, line: line)
        // Hosted iOS 26 can animate the 50ms synthesized tap without committing
        // selection. Send one deliberate touch, then prove navigation before
        // attributing a missing loading state to the destination screen.
        button.press(forDuration: 0.1)
        XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: gateTimeout), app.debugDescription, file: file, line: line)
    }
}
