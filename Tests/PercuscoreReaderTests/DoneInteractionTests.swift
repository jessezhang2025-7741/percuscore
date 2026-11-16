import XCTest
import UIKit
import PencilKit
import Combine
@testable import Percuscore

@MainActor
final class DoneInteractionTests: XCTestCase {
    func testQueuedRefreshCannotRestoreInputAfterRepresentableDismantle() async throws {
        let (model, surface, window) = try makeSurface()
        defer { window.isHidden = true }
        model.beginAnnotation(); surface.refresh()
        await nextMainTurn()
        XCTAssertTrue(model.canvas.isFirstResponder)
        surface.requestRefresh(inputEnabled: true)
        surface.invalidate()
        surface.requestRefresh(inputEnabled: true)
        for _ in 0..<3 { await nextMainTurn() }
        XCTAssertNotNil(surface.window, "Retain the outgoing view during the transition")
        XCTAssertFalse(model.canvas.isFirstResponder)
        XCTAssertFalse(surface.isFirstResponder)
        surface.refresh()
        await nextMainTurn()
        XCTAssertFalse(model.canvas.isFirstResponder)
    }

    func testBackgroundRepresentableUpdatesReachUIKitThroughMainQueue() async throws {
        let (_, surface, window) = try makeSurface()
        defer { surface.hideToolPicker(); window.isHidden = true }
        await nextMainTurn()
        XCTAssertTrue(surface.isFirstResponder)
        let disabled = expectation(description: "Background representable update queued")
        DispatchQueue.global().async {
            surface.requestRefresh(inputEnabled: false)
            disabled.fulfill()
        }
        await fulfillment(of: [disabled], timeout: 2)
        await nextMainTurn()
        XCTAssertFalse(surface.isFirstResponder)
        let enabled = expectation(description: "Background representable update resumed")
        DispatchQueue.global().async {
            surface.requestRefresh(inputEnabled: true)
            enabled.fulfill()
        }
        await fulfillment(of: [enabled], timeout: 2)
        await nextMainTurn()
        XCTAssertTrue(surface.isFirstResponder)
    }

    func testPanelKeepsTextFocusDuringRefreshAndReaderResumesAfterDismissal() async throws {
        let (_, surface, window) = try makeSurface()
        defer { surface.hideToolPicker(); window.isHidden = true }
        await nextMainTurn()
        let field = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        window.rootViewController!.view.addSubview(field)
        surface.readerInputEnabled = false; surface.refresh()
        await nextMainTurn()
        XCTAssertTrue(field.becomeFirstResponder())
        for _ in 0..<3 { surface.refresh(); await nextMainTurn() }
        XCTAssertTrue(field.isFirstResponder, "Underlying reader must not steal a panel's text focus")
        XCTAssertFalse(surface.isFirstResponder)
        field.removeFromSuperview()
        surface.readerInputEnabled = true; surface.refresh()
        await nextMainTurn()
        XCTAssertTrue(surface.isFirstResponder, "Keyboard page turns must resume after dismissal")
    }

    func testPanelSuppressesQueuedAnnotationFocus() async throws {
        let (model, surface, window) = try makeSurface()
        defer { surface.hideToolPicker(); window.isHidden = true }
        model.beginAnnotation(); surface.refresh()
        surface.readerInputEnabled = false; surface.refresh()
        await nextMainTurn()
        XCTAssertFalse(model.canvas.isFirstResponder)
        XCTAssertFalse(surface.isFirstResponder)
        surface.readerInputEnabled = true; surface.refresh()
        await nextMainTurn()
        XCTAssertTrue(model.canvas.isFirstResponder)
    }

    func testDoneKeepsResponderChangesOutsideSurfaceRefresh() async throws {
        let (model, surface, window) = try makeSurface()
        defer { surface.hideToolPicker(); window.isHidden = true }
        model.beginAnnotation(); surface.refresh()
        await nextMainTurn()
        XCTAssertTrue(model.canvas.isFirstResponder)

        XCTAssertTrue(model.saveAnnotation())
        surface.refresh()
        XCTAssertTrue(model.canvas.isFirstResponder,
                      "Refreshing inside a SwiftUI update must not synchronously change the responder chain")
        await nextMainTurn()
        XCTAssertFalse(model.canvas.isFirstResponder)
        XCTAssertTrue(surface.isFirstResponder, "Keyboard page turns must work after Done")
    }

    func testQueuedDoneUsesLatestAnnotationMode() async throws {
        let (model, surface, window) = try makeSurface()
        defer { surface.hideToolPicker(); window.isHidden = true }
        model.beginAnnotation(); surface.refresh()
        await nextMainTurn()
        XCTAssertTrue(model.canvas.isFirstResponder)

        XCTAssertTrue(model.saveAnnotation()); surface.refresh()
        model.beginAnnotation(); surface.refresh()
        await nextMainTurn()
        XCTAssertEqual(model.mode, .annotating)
        XCTAssertTrue(model.canvas.isFirstResponder, "An older Done update must not steal focus from new markup")
        XCTAssertFalse(surface.isFirstResponder)
    }

    func testDismissalSuppressesPendingToolPickerPresentation() async throws {
        let (model, surface, window) = try makeSurface()
        defer { window.isHidden = true }
        await nextMainTurn()
        model.beginAnnotation(); surface.refresh()
        surface.hideToolPicker()
        await nextMainTurn()
        XCTAssertFalse(model.canvas.isFirstResponder)
        XCTAssertFalse(surface.isFirstResponder)
    }

    func testSaveAndTurnTransfersFocusToCurrentCanvas() async throws {
        let (model, surface, window) = try makeSurface()
        defer { surface.hideToolPicker(); window.isHidden = true }
        model.beginAnnotation(); surface.refresh()
        await nextMainTurn()
        let previous = model.canvas
        model.turn(forward: true); surface.refresh()
        await nextMainTurn()
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertEqual(model.mode, .annotating)
        XCTAssertFalse(previous.isFirstResponder)
        XCTAssertTrue(model.canvas.isFirstResponder)
        XCTAssertNotNil(model.canvas.superview)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeSurface() throws -> (ReaderModel, ScoreSurfaceView, UIWindow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DoneInteraction-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Done interaction", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score] })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        let model = ReaderModel(store: store, session: try XCTUnwrap(ReadingSession(queue: [item])))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        let controller = UIViewController()
        window.rootViewController = controller
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        controller.view.addSubview(surface); surface.frame = window.bounds
        window.makeKeyAndVisible()
        return (model, surface, window)
    }

    func testSurfaceRefreshDoesNotPublishReaderChangesWhenClosingMarkup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DoneInteraction-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Done interaction", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score] })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        let model = ReaderModel(store: store, session: try XCTUnwrap(ReadingSession(queue: [item])))
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = controller
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        controller.view.addSubview(surface); surface.frame = window.bounds
        window.makeKeyAndVisible()
        defer { surface.hideToolPicker(); window.isHidden = true }
        model.beginAnnotation(); surface.refresh(); surface.layoutIfNeeded()
        await nextMainTurn()
        XCTAssertTrue(model.saveAnnotation())
        var publications = 0
        let observer = model.objectWillChange.sink {
            publications += 1
        }
        surface.refresh(); surface.layoutIfNeeded()
        withExtendedLifetime(observer) {
            XCTAssertEqual(publications, 0, "UIView refresh must not invalidate the SwiftUI update that called it")
        }
        await nextMainTurn()
        XCTAssertEqual(model.mode, .reading)
        XCTAssertFalse(model.canvas.isFirstResponder)
    }
}
