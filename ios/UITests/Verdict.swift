import XCTest

extension XCUIElement {
    /// Waits until the element exists with a label passing `done`. XCTest's own waits read once a
    /// second, which cost every fixture launch about two idle seconds; this reads every 0.1s.
    func waitForLabel(timeout: TimeInterval, _ done: (String) -> Bool = { _ in true }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if exists, done(label) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }
}
