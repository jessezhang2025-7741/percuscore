import XCTest

/// The disposable host uses the production ReaderView, ScoreSurface and persistence.
/// Finger drawing stands in for Pencil input; real Pencil acceptance remains manual.
final class LiveReaderRelaunchUITests: XCTestCase {
    func testDrawDoneTurnAndRelaunchPreservesPageAndInk() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_REAL_BODY"] = "1"
        app.launchEnvironment["TOOLBAR_FINGER_INPUT"] = "1"
        app.launchEnvironment["VALIDATION_RELAUNCH_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 15))
        app.buttons["Annotate"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.43)))
        app.buttons["Done"].tap()
        assertText("Ink: 1 saved, 1 loaded", in: app)
        app.buttons["Next page"].tap()
        XCTAssertEqual(app.buttons["Quick page navigation"].value as? String, "2 / 4")
        assertText("Saved page: 2", in: app)
        app.terminate()
        app.launch()
        // Reading controls may already have auto-hidden while checking persistence.
        assertText("Saved page: 2", in: app)
        assertText("Ink: 0 saved, 0 loaded", in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        assertText("Saved page: 1", in: app)
        assertText("Ink: 1 saved, 1 loaded", in: app)
        XCTAssertFalse(app.buttons["Select All"].exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)
        app.terminate()
    }

    private func assertText(_ text: String, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), text)
    }
}
