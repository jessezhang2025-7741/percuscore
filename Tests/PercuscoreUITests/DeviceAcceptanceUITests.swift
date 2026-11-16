import XCTest

final class DeviceAcceptanceUITests: XCTestCase {
    private func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_ACCEPTANCE"] = "1"
        app.launchEnvironment["VALIDATION_ACCEPTANCE_ID"] = UUID().uuidString
        return app
    }
    func testManualOutcomeSurvivesRelaunchWithoutClaimingDevicePass() {
        continueAfterFailure = false
        let app = app(); app.launch()
        XCTAssertTrue(app.navigationBars["Device acceptance"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Simulator run — cannot pass physical-device acceptance."].exists)
        let chain = app.buttons["acceptance-input-chain"]
        app.swipeUp()
        XCTAssertTrue(chain.waitForExistence(timeout: 5)); chain.tap()
        app.buttons["acceptance-check-input-01"].tap()
        app.buttons["Failed"].tap()
        XCTAssertTrue(app.staticTexts["A failure was recorded in this run and remains part of its result."].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Device acceptance"].waitForExistence(timeout: 15))
        let result = app.descendants(matching: .any)["acceptance-status"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.value as? String, "Failed", app.debugDescription)
    }
    func testPrepareDefaultFixtureAndOpenIsolatedLibrary() {
        continueAfterFailure = false
        let app = app(); app.launch()
        XCTAssertTrue(app.buttons["Prepare test library"].waitForExistence(timeout: 15))
        app.buttons["Prepare test library"].tap()
        let open = app.buttons["Open test library"]
        let ready = NSPredicate(format: "exists == true AND enabled == true")
        expectation(for: ready, evaluatedWith: open)
        waitForExpectations(timeout: 360)
        open.tap()
        XCTAssertTrue(app.buttons["Exit test library"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["DEVICE ACCEPTANCE · ISOLATED TEST SCORES"].exists)
        app.buttons["Exit test library"].tap()
        XCTAssertTrue(app.navigationBars["Device acceptance"].waitForExistence(timeout: 10))
    }
}
