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

    private func values(_ label: String) -> [String: String] {
        Dictionary(label.split(separator: ";").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, last in last })
    }

    private func values() -> [String: String] { values(app.staticTexts["skip-state"].label) }

    // A stalled hosted simulator spent 10-19s on single skip-state reads after a
    // relaunch. XCTWaiter's 10s budget then expired mid-read and discarded a read
    // that already showed the target state. Judge every read that starts before
    // the deadline, and allow several of them; the required state is unchanged.
    /// Returns the read that satisfied `condition`, so callers need no slow re-read, or an empty
    /// read when it timed out without being `fatal`.
    @discardableResult
    private func wait(_ reason: String, timeout: TimeInterval = 30, fatal: Bool = true,
                      _ condition: ([String: String]) -> Bool) -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var label: String
        repeat {
            label = app.staticTexts["skip-state"].label
            let read = values(label)
            if condition(read) { return read }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        if fatal { XCTFail("\(reason) not reached within \(Int(timeout))s; last read: \(label)") }
        return [:]
    }

    /// Verify AVQueuePlayer's actual current item/time, not only the model's target position.
    private func at(_ seconds: Double) {
        let read = wait("paused at \(seconds)") { v in
            v["ready"] == "yes" && v["local"] == "yes" && v["paused"] == "yes" &&
            v["track"] == (seconds < 100 ? "0" : "1") &&
            abs((Double(v["actual"] ?? "") ?? -1000) - seconds) < 0.15 &&
            abs((Double(v["pos"] ?? "") ?? -1000) - seconds) < 0.15 &&
            v["rate"] == "0.00" && v["speed"] == "1.50" && v["default"] == "1.50"
        }
        // Attach the read that passed; another read costs 10-19s on a stalled simulator.
        let attachment = XCTAttachment(string: read.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))
        attachment.name = "Actual AVQueuePlayer at \(seconds)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A slow read can return long after a skip made during playback, so judge the landing the
    /// fixture latched from the actual AVQueuePlayer
    /// (`jump=from:fromRate:track:actual:rate:speed:after:slack`): playing at 1.5x from `range`,
    /// the skip crossed into `track` and landed `by` seconds away, allowing only for playback in
    /// the `after` seconds until the landing was read, then settled still playing at 1.5x.
    /// `actual` is the first reading after the jump and can be up to `slack` past the landing, so
    /// the lower bound subtracts it. `from` is sampled when the queue is rebuilt, which can trail
    /// the tap, hence 5s below; a landing at the target file's start stays well outside that.
    ///
    /// 1.5x playback leaves `range` about 13s after Play, and a stalled simulator can spend that
    /// on the Play read and skip tap alone. Such a skip may never latch (it started while the
    /// player was not progressing), or say nothing about crossing files, so it is retried from a
    /// fresh seed; the last attempt still judges it.
    private func playingSkip(_ direction: String, _ button: String, seed start: Int, from range: Range<Double>,
                             track: String, by delta: Double) {
        for attempt in 1...3 {
            seed(start)
            app.buttons["Play"].tap()
            // Rate 1.5 also shows while waiting to play; the fixture only latches a skip made
            // while playback is actually progressing.
            // A stall between two reads can also let playback run to the book's end, so before
            // the last attempt a missed Play wait is retried too.
            let playing = wait("playing at 1.5x", fatal: attempt == 3) {
                $0["rate"] == "1.50" && $0["paused"] == "no" && (Double($0["actual"] ?? "") ?? -1) > Double(start) + 0.2
            }
            if playing.isEmpty { pause(); continue }
            app.buttons[button].tap()
            let jump = wait("\(direction) cross-file playback retained", fatal: attempt == 3) { $0["jump"] != "none" }["jump"] ?? ""
            pause()
            let parts = jump.split(separator: ":").map(String.init)
            let attachment = XCTAttachment(string: jump)
            attachment.name = "Actual \(direction) skip landing during playback (attempt \(attempt))"
            attachment.lifetime = .keepAlways
            add(attachment)
            if attempt < 3, unclear(parts, from: range, by: delta) { continue }
            return judge(jump, parts, from: range, track: track, by: delta)
        }
    }

    /// Playback that reached the book's end already stopped and shows Play instead.
    private func pause() {
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        wait("paused") { $0["paused"] == "yes" }
    }

    /// No latch, a skip that started outside `range` (including one latched from the file-1
    /// rebuild tick at 100), a landing read more than 1s of playback late, or a forward landing
    /// read at or past 130, which a skip that started in file 1 also reaches.
    private func unclear(_ parts: [String], from range: Range<Double>, by delta: Double) -> Bool {
        guard parts.count == 8, let from = Double(parts[0]), let actual = Double(parts[3]), let slack = Double(parts[7]) else {
            return parts.isEmpty
        }
        return !range.contains(from) || slack > 1 || (delta > 0 && actual >= 100 + delta)
    }

    private func judge(_ jump: String, _ parts: [String], from range: Range<Double>, track: String, by delta: Double) {
        guard parts.count == 8, let from = Double(parts[0]), let actual = Double(parts[3]), let after = Double(parts[6]),
              let slack = Double(parts[7]) else {
            return XCTFail("skip landing malformed: \(jump)")
        }
        XCTAssertTrue(range.contains(from), "skip started outside the cross-file range: \(jump)")
        XCTAssertEqual(parts[1], "1.50", "not playing at 1.5x before the skip: \(jump)")
        XCTAssertEqual(parts[2], track, "skip did not cross files: \(jump)")
        // `from` can trail the skip, so playback may have crossed 100 first. A forward landing
        // under 130 shows the skip itself started in file 0; backward always starts in file 1.
        if delta > 0 { XCTAssertLessThan(actual, 100 + delta, "forward skip may have started in file 1: \(jump)") }
        XCTAssertGreaterThan(actual - slack, from + delta - 5, "skip landed short: \(jump)")
        XCTAssertLessThan(actual, from + delta + 1.5 * after + 1.5, "skip landed too far: \(jump)")
        XCTAssertEqual(parts[4], "1.50", "playback rate not retained: \(jump)")
        XCTAssertEqual(parts[5], "1.50", "speed not retained: \(jump)")
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
            // `from` is sampled up to one fixture tick before the tap, and the skip uses the model
            // position, so a sample just under 130 can still skip from 130 into file 1 (100).
            // That would be indistinguishable from a skip clamped within file 1, so leave a 1s
            // margin and let such a skip be retried as outside the window. Forward keeps the same
            // margin under 100, past which the skip would be an in-file seek within file 1.
            playingSkip("backward", route == "remote" ? "Remote back" : "Back 30 seconds",
                        seed: 110, from: 109.9..<129, track: "0", by: -30)
            playingSkip("forward", route == "remote" ? "Remote forward" : "Forward 30 seconds",
                        seed: 80, from: 79.9..<99, track: "1", by: 30)
        }
    }
}
