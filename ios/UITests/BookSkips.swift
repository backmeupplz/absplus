import XCTest

final class BookSkips: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--book-skip-test"]
        app.launch()
        at(110)
    }

    private func values() -> [String: String] {
        let label = app.staticTexts["skip-state"].label
        return Dictionary(label.split(separator: ";").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, last in last })
    }

    private func wait(_ reason: String, _ condition: @escaping ([String: String]) -> Bool) {
        let predicate = NSPredicate { [self] _, _ in condition(values()) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10), .completed,
                       "\(reason): \(app.staticTexts["skip-state"].label)")
    }

    /// Verify AVQueuePlayer's actual current item/time, not only the model's target position.
    private func at(_ seconds: Double) {
        wait("paused at \(seconds)") { v in
            v["ready"] == "yes" && v["local"] == "yes" && v["paused"] == "yes" &&
            v["track"] == (seconds < 100 ? "0" : "1") &&
            abs((Double(v["actual"] ?? "") ?? -1000) - seconds) < 0.15 &&
            abs((Double(v["pos"] ?? "") ?? -1000) - seconds) < 0.15 &&
            v["rate"] == "0.00" && v["speed"] == "1.50" && v["default"] == "1.50"
        }
        let attachment = XCTAttachment(string: app.staticTexts["skip-state"].label)
        attachment.name = "Actual AVQueuePlayer at \(seconds)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func seed(_ seconds: Int) { app.buttons["At \(seconds)"].tap(); at(Double(seconds)) }

    private func exercise(back: String, forward: String) {
        app.buttons[back].tap(); at(80) // file two -> file one, full 30s
        seed(95)
        app.buttons[forward].tap(); at(125) // file one -> file two, full 30s
        seed(60)
        app.buttons[back].tap(); at(30) // within file
        app.buttons[forward].tap(); at(60)
        app.buttons[forward].tap(); at(90)
        app.buttons[forward].tap(); at(120) // repeated across boundary
        app.buttons[forward].tap(); at(150) // exact end, not duration - 1
        app.buttons[forward].tap(); at(150) // clamped end remains stable
        app.buttons[back].tap(); at(120) // recover from exact end
        seed(140)
        app.buttons[forward].tap(); at(150) // overshoot end
        seed(10)
        app.buttons[back].tap(); at(0)
        app.buttons[back].tap(); at(0) // clamped beginning
    }

    func testFullPlayerButtonsCrossFilesAndClamp() {
        exercise(back: "Back 30 seconds", forward: "Forward 30 seconds")
    }

    func testRemoteCallbackBodiesCrossFilesAndClamp() {
        // These invoke the same handlers installed in MPRemoteCommandCenter.
        // XCTest cannot synthesize a real OS/headset MPRemoteCommandEvent.
        exercise(back: "Remote back", forward: "Remote forward")
        XCTAssertEqual(values()["remote"], "0") // MPRemoteCommandHandlerStatus.success
    }

    func testPlaybackAndSpeedSurviveBothCrossFileRoutes() {
        for route in ["FullPlayer", "remote"] {
            seed(110)
            app.buttons["Play"].tap()
            wait("playing at 1.5x") { $0["rate"] == "1.50" && $0["paused"] == "no" }
            app.buttons[route == "remote" ? "Remote back" : "Back 30 seconds"].tap()
            wait("backward cross-file playback retained") { v in
                v["track"] == "0" && v["ready"] == "yes" && v["rate"] == "1.50" &&
                v["speed"] == "1.50" && (Double(v["actual"] ?? "") ?? 0) > 79
            }
            app.buttons["Pause"].tap()
            wait("paused") { $0["paused"] == "yes" }
            seed(95)
            app.buttons["Play"].tap()
            wait("playing") { $0["rate"] == "1.50" }
            app.buttons[route == "remote" ? "Remote forward" : "Forward 30 seconds"].tap()
            wait("forward cross-file playback retained") { v in
                let time = Double(v["actual"] ?? "") ?? 0
                return v["track"] == "1" && v["ready"] == "yes" && v["rate"] == "1.50" &&
                    v["speed"] == "1.50" && time >= 124 && time < 145
            }
            app.buttons["Pause"].tap()
            wait("paused") { $0["paused"] == "yes" }
        }
    }
}
