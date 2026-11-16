import XCTest

final class SaveStatusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testSavedDraftStatusKeepsEssentialAnnotationActionsAvailable() {
        let app = launch()
        assertStatus("Saved", app: app)
        for name in ["Markup actions", "Done"] { XCTAssertTrue(app.buttons[name].isHittable) }
        snapshot(app, "save-status-saved-portrait")
    }

    func testPendingStrokeShowsSaving() {
        let app = launch(pending: true)
        assertStatus("Saving…", app: app)
        XCTAssertTrue(app.buttons["Done"].isHittable)
        snapshot(app, "save-status-saving-portrait")
    }

    func testFailedSaveKeepsRetryAndDoneVisibleAtLargeTextInANarrowWindow() {
        let app = launch(failed: true, largeText: true)
        assertStatus("Save failed", app: app)
        XCTAssertTrue(app.buttons["Retry save"].isHittable)
        XCTAssertTrue(app.buttons["Done"].isHittable)
        snapshot(app, "save-status-failed-narrow-large-text")
        app.buttons["Retry save"].tap()
        assertStatus("Save failed", app: app)
    }

    func testBackupPageDistinguishesNoRecordedExportFromPersistedSuccessfulExport() {
        let first = launch(backup: true)
        XCTAssertTrue(first.staticTexts["Last successful export"].waitForExistence(timeout: 4))
        XCTAssertTrue(first.staticTexts["No export recorded"].exists)
        first.terminate()
        let app = launch(backup: true, exported: true)
        XCTAssertTrue(app.staticTexts["Last successful export"].waitForExistence(timeout: 4))
        let time = app.staticTexts["Backup export time"]
        XCTAssertTrue(time.exists)
        XCTAssertTrue((time.value as? String)?.contains("2023") == true)
        XCTAssertFalse(app.staticTexts["No export recorded"].exists)
        snapshot(app, "backup-last-export-portrait")
    }

    private func launch(pending: Bool = false, failed: Bool = false, largeText: Bool = false,
                        backup: Bool = false, exported: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_WIDTH"] = largeText ? "320" : "834"
        app.launchEnvironment["TOOLBAR_LARGE_TEXT"] = largeText ? "1" : "0"
        app.launchEnvironment["TOOLBAR_PENDING_SAVE"] = pending ? "1" : "0"
        app.launchEnvironment["TOOLBAR_FAILED_DRAFT"] = failed ? "1" : "0"
        app.launchEnvironment["TOOLBAR_BACKUP"] = backup ? "1" : "0"
        app.launchEnvironment["TOOLBAR_BACKUP_EXPORTED"] = exported ? "1" : "0"
        app.launch()
        return app
    }
    private func assertStatus(_ value: String, app: XCUIApplication) {
        let status = app.otherElements["Save status"]
        XCTAssertTrue(status.waitForExistence(timeout: 4))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
