import XCTest

final class ReaderControlsUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_LIBRARY"] = "1"
        app.launchEnvironment["TOOLBAR_READING"] = "1"
        app.launchEnvironment["TOOLBAR_REAL_BODY"] = "1"
        app.launch()
        let title = app.staticTexts["Portrait markup practice"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))
        return app
    }
    private func waitUntilHidden(_ element: XCUIElement) {
        let hidden = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: element)], timeout: 5), .completed)
    }
    func testOpeningFromLibraryAndRepeatedCenterRevealAutoHideBothBars() {
        let app = launch()
        let library = app.buttons["Library"], navigation = app.buttons["Quick page navigation"]
        XCTAssertTrue(navigation.exists)
        waitUntilHidden(library)
        XCTAssertFalse(navigation.exists)
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(library.waitForExistence(timeout: 2))
            XCTAssertTrue(navigation.exists)
            waitUntilHidden(library)
            XCTAssertFalse(navigation.exists)
        }
    }
    func testAnnotationToolsStayVisibleAndDoneRestartsReadingCountdown() {
        let app = launch()
        app.buttons["Annotate"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3.3)
        XCTAssertTrue(done.exists)
        done.tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 2))
        waitUntilHidden(app.buttons["Library"])
    }

    func testAnnotateOpensDirectlyAtEveryReaderWidth() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for (width, largest) in [(320, false), (420, false), (834, false), (320, true)] {
            let app = XCUIApplication()
            app.launchEnvironment["TOOLBAR_READING"] = "1"
            app.launchEnvironment["TOOLBAR_WIDTH"] = String(width)
            app.launchEnvironment["TOOLBAR_MAX_TEXT"] = largest ? "1" : "0"
            app.launch()
            let annotate = app.buttons["Annotate"]
            XCTAssertTrue(annotate.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "Annotate").count, 1)
            XCTAssertTrue(annotate.isHittable)
            XCTAssertGreaterThanOrEqual(annotate.frame.width, 44)
            XCTAssertGreaterThanOrEqual(annotate.frame.height, 44)
            XCTAssertGreaterThanOrEqual(annotate.frame.minX, app.frame.midX - CGFloat(width) / 2 - 1)
            XCTAssertLessThanOrEqual(annotate.frame.maxX, app.frame.midX + CGFloat(width) / 2 + 1)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "direct-annotate-\(width)-largest-\(largest)"
            screenshot.lifetime = .keepAlways; add(screenshot)
            annotate.tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
            app.buttons["Done"].tap()
            XCTAssertTrue(annotate.waitForExistence(timeout: 3))
            app.terminate()
        }
    }
    func testPageNavigatorPausesHideAndDismissalRestartsCountdown() {
        let app = launch()
        app.buttons["Quick page navigation"].tap()
        let close = app.buttons["Close page navigator"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3.3)
        XCTAssertTrue(close.exists)
        close.tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 2))
        waitUntilHidden(app.buttons["Library"])
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Quick page navigation"].waitForExistence(timeout: 2))
    }
}
