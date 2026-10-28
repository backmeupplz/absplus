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

extension XCUIApplication {
    /// A tab's button: in the tab bar, or in the vertical rail iOS 27.1 puts beside the status pill on an iPhone Duo's
    /// cover display, which is not a tab bar.
    func tab(_ name: String, timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for e in [tabBars.buttons[name], tabs[name], buttons[name]] where e.exists { return e }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return tabBars.buttons[name]
    }

    /// The navigation back button: in the navigation bar, or beside the status pill on an iPhone Duo's cover display.
    var back: XCUIElement {
        let bar = navigationBars.buttons.element(boundBy: 0)
        return bar.exists ? bar : buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")).firstMatch
    }

    /// A toolbar button, wherever the system put it (the navigation bar, or beside an iPhone Duo's status pill).
    func barButton(_ name: String) -> XCUIElement {
        let bar = navigationBars.buttons[name]
        return bar.exists ? bar : buttons[name].firstMatch
    }
}
