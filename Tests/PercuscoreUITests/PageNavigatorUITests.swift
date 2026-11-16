import XCTest

final class PageNavigatorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testTypedPageRejectsInvalidInputAndJumpsToTheEnteredPDFPage() {
        let app = launch()
        openPanel(app)
        enter("0", in: app)
        XCTAssertFalse(app.buttons["Jump to page"].isEnabled)
        enter("5", in: app)
        XCTAssertFalse(app.buttons["Jump to page"].isEnabled)
        enter("3", in: app)
        app.buttons["Jump to page"].tap()
        assertPage("3 / 4", in: app)
    }

    func testThumbnailSelectionJumpsAndMarksTheCurrentPage() {
        let app = launch()
        openPanel(app)
        XCTAssertTrue((app.buttons["Go to page 1"].value as? String)?.contains("Current page") == true)
        saveSnapshot(app, name: "page-navigator-grid")
        app.buttons["Go to page 4"].tap()
        assertPage("4 / 4", in: app)
    }

    func testContentsOffersNamedBookmarksAndPDFMovements() {
        let app = launch()
        openPanel(app)
        app.buttons["Contents"].tap()
        XCTAssertTrue(app.buttons["II. Adagio, Page 3"].waitForExistence(timeout: 3))
        saveSnapshot(app, name: "page-navigator-contents")
        app.buttons["Cue B, Page 2"].tap()
        assertPage("2 / 4", in: app)
        openPanel(app)
        app.buttons["Contents"].tap()
        app.buttons["II. Adagio, Page 3"].tap()
        assertPage("3 / 4", in: app)
    }

    func testClosingWithoutJumpKeepsAnnotationModeAndCurrentPage() {
        let app = launch(reading: false)
        openPanel(app)
        app.buttons["Close page navigator"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Markup actions"].isHittable)
        assertPage("1 / 4", in: app)
    }

    func testLongScoreOpensAtCurrentPageAndJumpsToLastPage() {
        let app = launch(longScore: true)
        openPanel(app)
        XCTAssertTrue(app.buttons["Go to page 89"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Go to page 89"].isHittable)
        saveSnapshot(app, name: "page-navigator-long-current")
        enter("120", in: app)
        app.buttons["Jump to page"].tap()
        assertPage("120 / 120", in: app)
        openPanel(app)
        XCTAssertTrue(app.buttons["Go to page 120"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Go to page 120"].isHittable)
    }

    func testFailedSaveKeepsNavigatorAndCurrentPageOpen() {
        let app = launch(reading: false, failedSave: true)
        openPanel(app)
        app.buttons["Go to page 3"].tap()
        XCTAssertTrue(app.buttons["Close page navigator"].exists)
        XCTAssertTrue(app.staticTexts["PDF pages 1–4 · Current page 1"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page jump failed:")).firstMatch.exists)
    }

    private func launch(reading: Bool = true, failedSave: Bool = false, longScore: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_WIDTH"] = "420"
        app.launchEnvironment["TOOLBAR_READING"] = reading ? "1" : "0"
        app.launchEnvironment["TOOLBAR_FAILED_SAVE"] = failedSave ? "1" : "0"
        app.launchEnvironment["TOOLBAR_LONG_SCORE"] = longScore ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["Quick page navigation"].waitForExistence(timeout: 5))
        return app
    }
    private func openPanel(_ app: XCUIApplication) {
        app.buttons["Quick page navigation"].tap()
        XCTAssertTrue(app.textFields["PDF page number"].waitForExistence(timeout: 3))
    }
    private func enter(_ value: String, in app: XCUIApplication) {
        let field = app.textFields["PDF page number"]
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
    }
    private func assertPage(_ value: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value),
            object: app.buttons["Quick page navigation"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
        XCTAssertFalse(app.textFields["PDF page number"].exists)
    }
    private func saveSnapshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
