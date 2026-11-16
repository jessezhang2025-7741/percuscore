import XCTest

final class LargePDFPerformanceUITests: XCTestCase {
    func testScannedScore() throws {
        guard ProcessInfo.processInfo.environment["LARGE_PDF_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in large scan benchmark")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PERFORMANCE_RUNSET"] = ProcessInfo.processInfo.environment["PERFORMANCE_RUNSET"] ?? "default"
        app.launch()
        let score = app.buttons.containing(.staticText, identifier: "Large scanned score").firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 10)); score.tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 10))
        let geometry = ["Library", "Previous page", "Next page", "Quick page navigation"].map { name in
            ["name": name, "x": app.buttons[name].frame.minX, "y": app.buttons[name].frame.minY,
             "width": app.buttons[name].frame.width, "height": app.buttons[name].frame.height] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: geometry)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "glass-control-geometry"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.staticTexts["Performance complete"].waitForExistence(timeout: 300))
        app.terminate()
    }
}
