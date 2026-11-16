import XCTest

final class AnnotationToolbarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testEssentialActionsFitPortraitAndNarrowWindows() {
        for width in [320, 420, 768, 834] {
            let app = launch(width: width)
            assertEssentialActions(app, width: width)
            saveSnapshot(app, name: "portrait-\(width)")
            app.terminate()
        }
    }

    func testEssentialActionsFitLargeTextInNarrowWindows() {
        for width in [320, 420] {
            let app = launch(width: width, largeText: true)
            assertEssentialActions(app, width: width)
            saveSnapshot(app, name: "accessibility-\(width)")
            app.terminate()
        }
    }

    func testAppToolbarLeavesUndoRedoToPencilKitAndDoneStillWorks() {
        let app = launch(width: 420)
        // This fixture shows the app toolbar without the native PencilKit palette.
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertFalse(app.buttons["Redo"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Done"].exists)
    }

    func testMoreMenuKeepsPageNavigationAndCancelAvailable() {
        let app = launch(width: 420)
        app.buttons["Markup actions"].tap()
        saveSnapshot(app, name: "menu-420")
        app.buttons["Save and annotate next page"].tap()
        XCTAssertEqual(app.buttons["Quick page navigation"].value as? String, "2 / 4")
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Markup actions"].tap()
        app.buttons["Save and annotate previous page"].tap()
        XCTAssertEqual(app.buttons["Quick page navigation"].value as? String, "1 / 4")
        app.buttons["Markup actions"].tap()
        app.buttons["Cancel annotation changes"].tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Done"].exists)
    }

    func testDoneWithLiveCanvasLeavesReaderControlsResponsive() {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_REAL_BODY"] = "1"
        app.launchEnvironment["TOOLBAR_WIDTH"] = "834"
        app.launchEnvironment["TOOLBAR_FINGER_INPUT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45)))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        app.buttons["Annotate"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))
        app.buttons["Quick page navigation"].tap()
        XCTAssertTrue(app.buttons["Jump to page"].waitForExistence(timeout: 5))
        let pageNumber = app.textFields["PDF page number"]
        pageNumber.tap(); pageNumber.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        app.buttons["Jump to page"].tap()
        XCTAssertEqual(app.buttons["Quick page navigation"].value as? String, "2 / 4")
    }

    func testReadingTapOverSavedInkTurnsPageWithoutSelectionMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_REAL_BODY"] = "1"
        app.launchEnvironment["TOOLBAR_WIDTH"] = "834"
        app.launchEnvironment["TOOLBAR_FINGER_INPUT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.43))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.43)))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.43)).tap()
        XCTAssertEqual(app.buttons["Quick page navigation"].value as? String, "2 / 4")
        XCTAssertFalse(app.buttons["Select All"].exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
    }

    private func launch(width: Int, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_WIDTH"] = String(width)
        app.launchEnvironment["TOOLBAR_LARGE_TEXT"] = largeText ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        return app
    }

    private func assertEssentialActions(_ app: XCUIApplication, width: Int) {
        let left = app.frame.midX - CGFloat(width) / 2
        let right = left + CGFloat(width)
        var frames: [CGRect] = []
        for label in ["Markup actions", "Done"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, label)
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(frame.height, 44, label)
            XCTAssertGreaterThanOrEqual(frame.minX, left - 1, "\(label) outside the visible reader")
            XCTAssertLessThanOrEqual(frame.maxX, right + 1, "\(label) outside the visible reader")
            XCTAssertTrue(button.isHittable, "\(label) hidden or clipped")
            for other in frames { XCTAssertFalse(other.intersects(frame), "Essential actions overlap") }
            frames.append(frame)
        }
    }

    private func saveSnapshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
