import XCTest

// Temporary probe for #98; not committed.
final class ListProbe98: XCTestCase {
    func testProbeEdgeSwipeMinXPadding() { probe(margins: false) }
    func testProbeEdgeSwipeMinXMargins() { probe(margins: true) }

    private func probe(margins: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--list-lifecycle-test"]
        if margins { app.launchEnvironment["ABS98_MARGINS"] = "1" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Title 000"].waitForExistence(timeout: 30))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 { scroll.swipeUp() }
        let titles = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Title '"))
        let target = titles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < 700 && $0.frame.minX < 30 }!
        let name = target.label
        print("PROBE98 anchor \(name) x=\(target.frame.minX) y=\(target.frame.minY)")
        let cycles = Int(ProcessInfo.processInfo.environment["PROBE98_CYCLES"] ?? "") ?? 10
        var shifted = 0
        for i in 0..<cycles {
            guard app.staticTexts[name].waitForExistence(timeout: 30) else { print("PROBE98 \(i) anchor missing"); break }
            app.staticTexts[name].tap()
            guard app.staticTexts["Fixture details"].firstMatch.waitForExistence(timeout: 30) else { print("PROBE98 \(i) no details"); break }
            try? "\(i)".write(toFile: "/tmp/abs98-trigger", atomically: true, encoding: .utf8)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            let details = app.staticTexts["Fixture details"].firstMatch
            let popped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: details)
            let r = XCTWaiter.wait(for: [popped], timeout: 40)
            if r != .completed {
                print("PROBE98 \(i) not popped; tapping back")
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            sleep(3)
            let e = app.staticTexts[name]
            let x = e.exists ? e.frame.minX : -1
            if e.exists && abs(x - 16) > 2 {
                shifted += 1
                let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "shifted-\(i)"; shot.lifetime = .keepAlways; add(shot)
                // Does it stay shifted while the app is idle and responsive?
                sleep(5)
                print("PROBE98 \(i) after 5s more x=\(e.frame.minX)")
            }
            print("PROBE98 \(i) popped=\(r == .completed) exists=\(e.exists) x=\(x) y=\(e.exists ? e.frame.minY : -1)")
        }
        print("PROBE98 margins=\(margins) shifted \(shifted)/\(cycles)")
        XCTAssertEqual(shifted, 0, "PROBE98 margins=\(margins) shifted \(shifted)/\(cycles)")
    }
}
