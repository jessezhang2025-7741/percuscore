import XCTest
import UIKit
@testable import Percuscore

@MainActor
final class AccessibilityTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ReaderModel, ScoreSurfaceView) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Accessibility-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let score = Score(title: "Accessible rehearsal", pageCount: 4)
        try SampleScore.write(to: XCTUnwrap(store.disk).pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings.halfPageTurns = true })
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 3)]))
        let model = ReaderModel(store: store, session: session)
        model.turn(forward: true)
        XCTAssertTrue(model.session.showingTransition)
        let view = ScoreSurfaceView(model: model, displayOptions: {})
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        view.layoutIfNeeded()
        return (store, model, view)
    }
    private func element(in view: UIView, prefix: String) -> UIView? {
        if view.isAccessibilityElement, view.accessibilityLabel?.hasPrefix(prefix) == true { return view }
        return view.subviews.lazy.compactMap { self.element(in: $0, prefix: prefix) }.first
    }
    func testDividerVoiceOverAdjustsByFivePercentAndPersistsOnItsPage() throws {
        let (store, model, view) = try fixture()
        let divider = try XCTUnwrap(element(in: view, prefix: "Half-page divider"))
        XCTAssertTrue(divider.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(divider.accessibilityValue, "50 percent from top")
        divider.accessibilityIncrement()
        XCTAssertEqual(model.layout.divider, 0.55, accuracy: 0.0001)
        XCTAssertEqual(divider.accessibilityValue, "55 percent from top")
        XCTAssertEqual(try XCTUnwrap(store.disk).load().scores[0].layouts[0]?.divider, 0.55)
        divider.accessibilityDecrement()
        XCTAssertEqual(model.layout.divider, 0.50, accuracy: 0.0001)
        XCTAssertEqual(model.pageIndex, 0)
        XCTAssertGreaterThanOrEqual(divider.frame.height, 44)
    }
    func testDividerAdjustmentsClampAtBothBounds() throws {
        let (_, model, view) = try fixture()
        let divider = try XCTUnwrap(element(in: view, prefix: "Half-page divider"))
        for _ in 0..<8 { divider.accessibilityIncrement() }
        XCTAssertEqual(model.layout.divider, 0.75, accuracy: 0.0001)
        for _ in 0..<15 { divider.accessibilityDecrement() }
        XCTAssertEqual(model.layout.divider, 0.25, accuracy: 0.0001)
    }
    func testPerformanceDividerRemainsReadableAndCannotBeAdjusted() throws {
        let (_, model, view) = try fixture()
        model.enterPerformance(); view.refresh()
        let divider = try XCTUnwrap(element(in: view, prefix: "Half-page divider"))
        XCTAssertFalse(divider.accessibilityTraits.contains(.adjustable))
        XCTAssertTrue(divider.accessibilityTraits.contains(.notEnabled))
        divider.accessibilityIncrement()
        XCTAssertEqual(model.layout.divider, 0.5)
    }
    func testCroppingRelinquishesKeyboardFocusAndRestoresItWhenDone() async throws {
        let (_, model, view) = try fixture()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { view.hideToolPicker(); window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.isFirstResponder)
        model.beginCrop(); view.refresh()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(view.isFirstResponder)
        model.saveCrop(); view.refresh()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(view.isFirstResponder)
    }
    func testScoreVoiceOverActionCanHideAndRevealControls() throws {
        let (_, model, view) = try fixture()
        let page = try XCTUnwrap(element(in: view, prefix: "Score page"))
        let hide = try XCTUnwrap(page.accessibilityCustomActions?.first { $0.name == "Hide reader controls" })
        XCTAssertEqual(hide.actionHandler?(hide), true)
        XCTAssertFalse(model.controlsVisible)
        let show = try XCTUnwrap(page.accessibilityCustomActions?.first { $0.name == "Show reader controls" })
        XCTAssertEqual(show.actionHandler?(show), true)
        XCTAssertTrue(model.controlsVisible)
    }
    func testScoreOffersAccessibleNavigationAndPerformanceExit() throws {
        let (_, model, view) = try fixture()
        let page = try XCTUnwrap(element(in: view, prefix: "Score page"))
        XCTAssertTrue(page.accessibilityValue?.contains("1 of 4") == true)
        let next = try XCTUnwrap(page.accessibilityCustomActions?.first { $0.name == "Next page" })
        XCTAssertEqual(next.actionHandler?(next), true)
        XCTAssertEqual(model.pageIndex, 1)
        model.enterPerformance(); view.refresh()
        let exit = try XCTUnwrap(page.accessibilityCustomActions?.first { $0.name == "Exit performance" })
        XCTAssertEqual(exit.actionHandler?(exit), true)
        XCTAssertFalse(model.performance.isActive)
        XCTAssertTrue(model.controlsVisible)
    }
}
