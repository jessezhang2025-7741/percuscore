import XCTest

final class RecentlyDeletedUITests: XCTestCase {
    func testDeleteRestoreAndInspectStorage() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TOOLBAR_LIBRARY"] = "1"
        app.launchEnvironment["TOOLBAR_WIDTH"] = "1194"
        app.launch()
        let title = app.staticTexts["Portrait markup practice"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.press(forDuration: 1.1)
        let move = app.buttons["Move to Recently Deleted"]
        XCTAssertTrue(move.waitForExistence(timeout: 5)); move.tap()
        XCTAssertTrue(app.alerts["Move to Recently Deleted?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Move"].tap()
        let deleted = app.collectionViews["Sidebar"].cells.containing(.staticText, identifier: "Recently Deleted").firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 5)); deleted.tap()
        let restore = app.buttons["Restore Portrait markup practice"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5), app.debugDescription)
        restore.tap()
        XCTAssertTrue(app.staticTexts["No recently deleted scores"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Permanently delete 1 score?"].exists,
                       "Restoring must not invoke the neighboring permanent-delete action")
        app.collectionViews["Sidebar"].cells.containing(.staticText, identifier: "All scores").firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.collectionViews["Sidebar"].cells.containing(.staticText, identifier: "Recently Deleted").firstMatch.tap()
        app.buttons["Storage management"].tap()
        XCTAssertTrue(app.staticTexts["Total file size"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recently Deleted (included above)"].exists)
        let clearCache = app.buttons["Clear cache…"]
        for _ in 0..<5 {
            if clearCache.exists && clearCache.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(clearCache.exists && clearCache.isHittable)
        clearCache.tap()
        XCTAssertTrue(app.alerts["Clear cache?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Clear cache"].tap()
        let pdfs = app.staticTexts["PDFs"]
        for _ in 0..<5 {
            if pdfs.exists { break }
            app.swipeDown()
        }
        XCTAssertTrue(pdfs.waitForExistence(timeout: 5))
    }
}
