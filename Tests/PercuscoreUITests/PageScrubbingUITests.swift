import XCTest

final class PageScrubbingUITests: XCTestCase {
    func testRapidScrubbingLongPDFKeepsReaderAliveAndLandsOnLastPage() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_LIBRARY"] = "1"
        app.launchEnvironment["TOOLBAR_READING"] = "1"
        app.launchEnvironment["TOOLBAR_REAL_BODY"] = "1"
        app.launchEnvironment["TOOLBAR_LONG_SCORE"] = "1"
        // Keep chrome visible for this long automation sequence; idle hiding
        // is verified separately by ReaderControlsUITests.
        app.launchEnvironment["TOOLBAR_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launch()
        let score = app.staticTexts["Portrait markup practice"].firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 15)); score.tap()
        let slider = app.sliders["Page position"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        for target in [0.95, 0.05, 1.0] {
            if !slider.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            XCTAssertTrue(slider.waitForExistence(timeout: 2))
            slider.adjust(toNormalizedSliderPosition: target)
        }
        for _ in 0..<5 {
            let right = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            let left = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            right.press(forDuration: 0.01, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            left.press(forDuration: 0.01, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
        }
        // Normalized accessibility adjustments can stop one step short. A real
        // drag beyond the track end exercises the actual last-page boundary.
        slider.adjust(toNormalizedSliderPosition: 0)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 1.05, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        let current = app.buttons["Quick page navigation"]
        if !current.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(current.waitForExistence(timeout: 2))
        XCTAssertEqual(current.value as? String, "120 / 120")
        let title = app.descendants(matching: .any)["Current score"].firstMatch
        XCTAssertTrue((title.value as? String)?.hasSuffix("page 120") == true,
                      "Check the loaded page, not just the slider's preview label")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "120-page-reader-after-fast-scrubbing"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
