import XCTest

final class ReaderGlassPanelsUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for key in ["TOOLBAR_LIBRARY", "TOOLBAR_READING", "TOOLBAR_REAL_BODY", "TOOLBAR_LONG_SCORE"] {
            app.launchEnvironment[key] = "1"
        }
        app.launch()
        let score = app.staticTexts["Portrait markup practice"].firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 15)); score.tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))
        return app
    }

    private func scrubToEnd(_ app: XCUIApplication, screenshotName: String) {
        let slider = app.sliders["Page position"]
        freshlyRevealSlider(app)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        // The dedicated scrubbing test covers ten uninterrupted fast drags.
        // Here each panel adds two round trips plus a final boundary drag.
        for _ in 0..<2 {
            freshlyRevealSlider(app)
            let right = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            let left = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            right.press(forDuration: 0.01, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            freshlyRevealSlider(app)
            left.press(forDuration: 0.01, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
        }
        freshlyRevealSlider(app)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        freshlyRevealSlider(app)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 1.05, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        freshlyRevealSlider(app)
        // Match the public loaded-page check in PageScrubbingUITests. The paper
        // view's UIKit accessibility element is not exposed by every SwiftUI host.
        let title = app.descendants(matching: .any)["Current score"].firstMatch
        let loaded = title.value as? String
        let landedPage = loaded?.split(separator: " ").last.flatMap { Int($0) }
        XCTAssertTrue(landedPage.map { (110...120).contains($0) } == true, loaded ?? "No loaded-page value")
        // Fast touch sampling is approximate (unlike AX normalized adjustment).
        // Verify the exact boundary through the real navigator after the drags.
        app.buttons["Quick page navigation"].tap()
        let field = app.textFields["PDF page number"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "120")
        app.buttons["Jump to page"].tap()
        freshlyRevealSlider(app)
        XCTAssertTrue((title.value as? String)?.hasSuffix("page 120") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private func freshlyRevealSlider(_ app: XCUIApplication) {
        // Start each fast drag with a full visibility deadline. Existing controls
        // tests separately verify the timer; use real taps rather than AX edits.
        let slider = app.sliders["Page position"]
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: slider)
        if slider.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // A tap may coincide with the automatic deadline; retry once if
            // that race revealed the bars instead of hiding them.
            if XCTWaiter.wait(for: [hidden], timeout: 2) != .completed {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let hiddenAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: slider)
                XCTAssertEqual(XCTWaiter.wait(for: [hiddenAgain], timeout: 2), .completed)
            }
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))
    }

    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testBookmarkEditorCancelAndJumpThenRapidScrubbing() {
        let app = launch()
        app.buttons["Bookmarks"].tap()
        let edit = app.buttons["Edit bookmark Cue B"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        screenshot(app, name: "native-glass-bookmarks")
        edit.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Cue B")
        field.tap(); field.typeText(" revised")
        XCTAssertTrue((field.value as? String)?.contains("revised") == true)
        app.buttons["Cancel"].tap()
        let jump = app.buttons["Go to Cue B, page 2"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3)); jump.tap()
        scrubToEnd(app, screenshotName: "after-bookmarks-fast-scrubbing")
    }

    func testPageNavigatorJumpThenRapidScrubbing() {
        let app = launch()
        app.buttons["Quick page navigation"].tap()
        let field = app.textFields["PDF page number"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        screenshot(app, name: "native-glass-page-navigator")
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "110")
        app.buttons["Jump to page"].tap()
        let title = app.descendants(matching: .any)["Current score"].firstMatch
        expectation(for: NSPredicate(format: "value ENDSWITH %@", "page 110"), evaluatedWith: title)
        waitForExpectations(timeout: 3)
        scrubToEnd(app, screenshotName: "after-page-navigator-fast-scrubbing")
    }

    func testDisplayOptionsRoundTripThenRapidScrubbing() {
        let app = launch()
        app.buttons["Display options"].tap()
        let toggle = app.switches["Half-page turns"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        screenshot(app, name: "native-reader-settings")
        let initial = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value != %@", initial ?? ""), evaluatedWith: toggle)
        waitForExpectations(timeout: 3)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", initial ?? ""), evaluatedWith: toggle)
        waitForExpectations(timeout: 3)
        app.buttons["Done"].tap()
        scrubToEnd(app, screenshotName: "after-display-options-fast-scrubbing")
    }
}
