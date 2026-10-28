import XCTest

/// Folding or unfolding an iPhone Duo changes the horizontal size class while the app runs. The fixture
/// (--fold-test) signs in to a stub server and adds a button that flips the size class the same way, live.
final class FoldState: XCTestCase {
    let app = XCUIApplication()
    var toggle: XCUIElement { app.buttons["fold.toggle"] }

    func fold(to size: String, line: UInt = #line) {
        // By coordinate: XCTest calls it not hittable while a sheet's keyboard is up, though it is.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(toggle.waitForLabel(timeout: 10) { _ in self.toggle.value as? String == size }, "size class did not become \(size)", line: line)
        sleep(1) // let the layout settle
    }

    func shot(_ name: String) {
        guard let out = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/fold-\(name).png"))
    }

    /// Checks that none of `elements` sits under what covers the screen (the iPhone Duo's status pill, iOS 27.1). The
    /// fixture puts those regions in the fold toggle's label; other phones have none, so this checks nothing there.
    func clearOfPill(_ elements: [XCUIElement], line: UInt = #line) {
        let regions = toggle.label.split(separator: ";").compactMap { s -> CGRect? in
            let n = s.split(separator: " ").compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }
        for e in elements where e.exists {
            for r in regions { XCTAssertFalse(r.intersects(e.frame), "\(e.identifier) \(e.label) at \(e.frame) is under \(r)", line: line) }
        }
    }

    func testFoldKeepsNavigationEditsSheetsAndPlayback() {
        continueAfterFailure = false
        // FOLD_ARGS (TEST_RUNNER_FOLD_ARGS for xcodebuild) adds launch arguments, e.g. to force right-to-left or the
        // largest accessibility text size.
        let extra = ProcessInfo.processInfo.environment["FOLD_ARGS"]?.split(separator: " ").map(String.init) ?? []
        let big = extra.contains { $0.hasPrefix("UICTContentSizeCategoryAccessibility") }
        app.launchArguments = ["--fold-test"] + extra
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        let start = toggle.value as? String ?? ""
        if start == "regular" { fold(to: "compact") } // an iPad or an unfolded Duo starts regular
        print("Occluded regions: [\(toggle.label)]")

        // Library: a search in progress and a title pushed on top of it.
        app.tab("Library").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("Pride\n") // submit, so the keyboard leaves the mini player visible later
        let tile = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Pride and Prejudice'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Moby-Dick'")).firstMatch.exists)
        tile.tap()
        let title = app.staticTexts["item.title"]
        let play = app.buttons.matching(NSPredicate(format: "label IN {'Play', 'Resume'}")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        // Title and author have different widths, so sharing a center means both are centered (under the cover). The
        // window's center would not do: on an iPhone Duo the status pill's column on the right is outside the page.
        let author = app.staticTexts["item.author"]
        XCTAssertEqual(title.frame.midX, author.frame.midX, accuracy: 2, "compact: the title is centered under the cover")
        let below = title.frame.minY
        play.tap()
        let mini = app.otherElements["mini"]
        XCTAssertTrue(mini.buttons["Pause"].waitForExistence(timeout: 30), "playback did not start")
        shot("1-compact-item")
        let pageControls = {
            [title, mini, self.app.back] + ["Home", "Library", "Series", "Favorites"].map { self.app.tab($0) }
                + self.app.collectionViews.firstMatch.buttons.allElementsBoundByIndex // play, download, favorite, share
        }
        clearOfPill(pageControls())

        // Unfold: same page, still playing, now with the cover beside the details.
        fold(to: "regular")
        XCTAssertTrue(title.exists, "the pushed title page was dropped")
        XCTAssertTrue(mini.buttons["Pause"].exists, "playback stopped")
        shot("2-regular-item")
        clearOfPill(pageControls())
        // Regular width alone is not room: a window narrower than the cover and its details side by side (a Duo's cover
        // display, or an iPhone, made regular here) keeps them stacked. Between the two widths depends on the margins.
        let width = app.windows.firstMatch.frame.width
        if big || width < 560 { XCTAssertEqual(title.frame.midX, author.frame.midX, accuracy: 2, "the title stays centered under the cover") }
        else if width >= 700 { XCTAssertLessThan(title.frame.minY, below - 100, "regular: the title sits beside the cover, not under it") }

        // Fold again and go back: the search is still there.
        fold(to: "compact")
        XCTAssertTrue(title.exists)
        XCTAssertEqual(title.frame.midX, author.frame.midX, accuracy: 2, "compact: the title is centered under the cover again")
        app.back.tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Pride", "the search text was lost")
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Moby-Dick'")).firstMatch.exists)

        // The full player stays open, playing, through both changes.
        mini.tap()
        let back = app.buttons["Back 30 seconds"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let elapsed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '0:0'")).firstMatch
        let before = elapsed.label
        fold(to: "regular")
        XCTAssertTrue(back.exists, "the full player closed")
        shot("3-regular-player")
        let playerControls = { [back, elapsed] + self.app.sliders.allElementsBoundByIndex
            + self.app.buttons.matching(NSPredicate(format: "label IN {'Forward 30 seconds', 'Pause'}")).allElementsBoundByIndex }
        clearOfPill(playerControls())
        fold(to: "compact")
        XCTAssertTrue(back.exists, "the full player closed")
        clearOfPill(playerControls())
        sleep(2)
        XCTAssertNotEqual(elapsed.label, before, "playback did not keep going")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists, "playback stopped")
        app.swipeDown(velocity: .fast)

        // A sheet with text being typed survives too.
        app.tab("Home").tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        clearOfPill([app.buttons["Settings"], app.navigationBars.staticTexts["Home"]])
        app.buttons["Settings"].tap()
        let link = app.buttons["Link account"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let user = app.textFields["Username"]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        user.tap()
        user.typeText("draft")
        fold(to: "regular")
        XCTAssertEqual(user.value as? String, "draft", "the sheet's text was lost")
        fold(to: "compact")
        XCTAssertEqual(user.value as? String, "draft", "the sheet's text was lost")
    }
}
