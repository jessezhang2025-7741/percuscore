import XCTest

final class BackupWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchEnvironment["TOOLBAR_BACKUP"] = "1"; app.launch(); return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
    func testInitialEvidenceAndCancellingSystemPickerNeverClaimVerified() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["File generated"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["System export completed"].exists)
        XCTAssertTrue(app.staticTexts["Restore verification: Not run"].exists)
        let choose = app.buttons["Choose backup to verify"]; reveal(choose, app: app); choose.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10)); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Restore verification: Not run"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["File passed restore verification"].exists)
    }
    func testPracticeLibraryOpensSeparatelyWithStandardScores() {
        let app = launch()
        let prepare = app.buttons["Prepare standard test library"]; reveal(prepare, app: app); prepare.tap()
        XCTAssertTrue(app.buttons["Open practice scores"].waitForExistence(timeout: 15)); app.buttons["Open practice scores"].tap()
        XCTAssertTrue(app.staticTexts["BACKUP PRACTICE · ISOLATED TEST SCORES"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Backup practice · Colors and draft"].exists)
        XCTAssertTrue(app.buttons["Exit test library"].exists)
        app.buttons["Exit test library"].tap()
        XCTAssertTrue(app.buttons["Close practice"].waitForExistence(timeout: 5)); app.buttons["Close practice"].tap()
        XCTAssertTrue(app.buttons["Prepare standard test library"].waitForExistence(timeout: 5))
    }
    func testVerifiedFileDetailsKeepPhysicalChecksIncompleteAndOpenRestoredCopy() {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_BACKUP"] = "1"
        app.launchEnvironment["TOOLBAR_BACKUP_VERIFIED"] = "1"
        app.launch()
        let details = app.buttons["File passed restore verification"]
        XCTAssertTrue(details.waitForExistence(timeout: 10)); reveal(details, app: app); details.tap()
        XCTAssertTrue(app.staticTexts["Restored, reopened and compared"].waitForExistence(timeout: 5))
        let physical = app.staticTexts["Result: incomplete"]; reveal(physical, app: app)
        XCTAssertTrue(physical.exists)
        XCTAssertTrue(app.staticTexts["Simulator run. Physical Files acceptance remains incomplete."].exists)
        let open = app.buttons["Open isolated restored library"]
        for _ in 0..<5 { if open.isHittable { break }; app.swipeDown() }
        open.tap()
        XCTAssertTrue(app.staticTexts["BACKUP VERIFICATION · ISOLATED RESTORED COPY"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Exit test library"].exists)
        app.buttons["Exit test library"].tap()
        XCTAssertTrue(app.navigationBars["Backup verification"].waitForExistence(timeout: 5))
    }

}
