import XCTest

final class AccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    private func launch(width: Int = 320, route: String = "READING", largest: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_ACCESSIBILITY"] = "1"
        app.launchEnvironment["TOOLBAR_WIDTH"] = String(width)
        app.launchEnvironment["TOOLBAR_\(route)"] = "1"
        if route == "HALF" { app.launchEnvironment["TOOLBAR_SURFACE"] = "1" }
        app.launchEnvironment["TOOLBAR_MAX_TEXT"] = largest ? "1" : "0"
        app.launch()
        return app
    }
    private func visibleTarget(_ button: XCUIElement, app: XCUIApplication, width: Int = 320) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.midX - CGFloat(width)/2 - 1)
        XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.midX + CGFloat(width)/2 + 1)
    }
    func testReaderPageControlsAtLargestTextInNarrowPortrait() {
        let app = launch()
        for name in ["Library", "Annotate", "Reader actions", "Previous page", "Next page", "Quick page navigation"] {
            visibleTarget(app.buttons[name], app: app)
        }
        snapshot(app, "reader-largest-320")
        app.buttons["Quick page navigation"].tap()
        XCTAssertTrue(app.textFields["PDF page number"].waitForExistence(timeout: 5))
        snapshot(app, "navigator-largest-320")
        visibleTarget(app.buttons["Jump to page"], app: app, width: 834)
    }
    func testCropControlsFitAndAdjustWithoutGestures() {
        let app = launch(route: "CROP")
        for name in ["Adjust crop", "Cancel", "Reset margins", "Save crop"] { visibleTarget(app.buttons[name], app: app) }
        snapshot(app, "crop-largest-320")
        app.buttons["Adjust crop"].tap()
        XCTAssertTrue(app.sliders["Straighten page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Crop scale"].exists)
        app.sliders["Crop scale"].adjust(toNormalizedSliderPosition: 0.3)
        snapshot(app, "crop-adjustments-largest")
        app.buttons["Done"].tap()
        app.buttons["Save crop"].tap()
        XCTAssertTrue(app.buttons["Quick page navigation"].waitForExistence(timeout: 5))
    }
    func testLibraryActionButtonsMeetMinimumTouchSize() {
        let app = launch(width: 834, route: "LIBRARY", largest: false)
        visibleTarget(app.buttons["Edit details"].firstMatch, app: app, width: 834)
        visibleTarget(app.buttons["Export PDF"].firstMatch, app: app, width: 834)
        snapshot(app, "library-standard-834")
        app.terminate()
        let largeApp = launch(width: 834, route: "LIBRARY")
        visibleTarget(largeApp.buttons["Edit details"].firstMatch, app: largeApp, width: 834)
        visibleTarget(largeApp.buttons["Export PDF"].firstMatch, app: largeApp, width: 834)
        snapshot(largeApp, "library-largest-834")
    }
    func testBookmarkEditTargetIsNamedAndSeparateFromNavigation() {
        let app = launch()
        app.buttons["Reader actions"].tap()
        app.buttons["Bookmarks"].tap()
        let edit = app.buttons["Edit bookmark Cue B"]
        visibleTarget(edit, app: app, width: 834)
        snapshot(app, "bookmarks-largest")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit bookmark"].waitForExistence(timeout: 5))
    }
    func testSetlistCanBeBuiltInNarrowPortraitAtLargestText() {
        let app = launch(route: "SETLIST")
        let title = "Concerto for percussion and orchestra — an extended rehearsal score"
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThanOrEqual(add.frame.width, 200)
        add.tap()
        snapshot(app, "setlist-largest-320")
        XCTAssertTrue(app.buttons["Done"].isHittable)
    }
    func testFullReaderCropHasUsableLargeTextControls() {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_ACCESSIBILITY"] = "1"
        app.launchEnvironment["TOOLBAR_WIDTH"] = "320"
        app.launchEnvironment["TOOLBAR_CROP"] = "1"
        app.launchEnvironment["TOOLBAR_REAL_BODY"] = "1"
        app.launchEnvironment["TOOLBAR_MAX_TEXT"] = "1"
        app.launch()
        for name in ["Library", "Adjust crop", "Save crop", "Reset margins", "Cancel"] {
            visibleTarget(app.buttons[name], app: app)
        }
        XCTAssertTrue(app.buttons["Crop help"].exists)
        snapshot(app, "full-reader-crop-largest-320")
    }
    func testHalfPageDividerIsDiscoverableInPortrait() {
        let app = launch(width: 834, route: "HALF", largest: false)
        let divider = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Half-page divider")).firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        XCTAssertEqual(divider.value as? String, "50 percent from top")
        XCTAssertGreaterThanOrEqual(divider.frame.height, 44)
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Score page")).firstMatch
        XCTAssertTrue(page.exists)
        XCTAssertTrue((page.value as? String)?.contains("page 1 of 4") == true)
        snapshot(app, "half-page-divider-portrait")
    }
    func testPresetSlidersHaveNamesAndValues() {
        let app = launch(width: 834, route: "PRESET")
        XCTAssertTrue(app.sliders["Ink width"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Ink opacity"].exists)
        snapshot(app, "preset-largest")
    }
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
