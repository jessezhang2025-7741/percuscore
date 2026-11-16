import XCTest
import UIKit
import PDFKit
@testable import Percuscore

@MainActor
final class ReaderViewportTests: XCTestCase {
    private func fixture() throws -> (ReaderModel, ScoreSurfaceView) {
        let store = LibraryStore()
        let disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Manual page views", pageCount: 3)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: disk.pdfURL(for: score.id)) { context in
            for _ in 0..<3 {
                context.beginPage(); UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 120, y: 180, width: 160, height: 240))
            }
        }
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings = ReaderSettings() })
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 2)]))
        let model = ReaderModel(store: store, session: session)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        surface.layoutIfNeeded()
        return (model, surface)
    }

    func testOpeningDoesNotAutomaticallyZoomWhenPreviewsArrive() async throws {
        let (model, surface) = try fixture()
        XCTAssertTrue(model.store.update { $0.settings.halfPageTurns = true })
        model.refreshSettings()
        for _ in 0..<150 {
            if model.transitionImage(next: false) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.transitionImage(next: false))
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.canvas.convert(model.canvas.bounds, to: surface).width, 800, accuracy: 1)
        model.enterPerformance()
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.canvas.convert(model.canvas.bounds, to: surface).width, 800, accuracy: 1)
    }

    func testZoomedPageTurnsWithoutAnExtraResetTap() throws {
        let (model, _) = try fixture()
        model.zoomed = true
        model.turn(forward: true)
        XCTAssertEqual(model.pageIndex, 1)
    }

    func testPerformanceAllowsManualPinchAndTwoFingerPan() throws {
        let (model, surface) = try fixture()
        model.enterPerformance(); surface.refresh()
        XCTAssertTrue(surface.gestureRecognizers?.contains { $0 is UIPinchGestureRecognizer && $0.isEnabled } ?? false)
        XCTAssertTrue(surface.gestureRecognizers?.contains {
            guard let pan = $0 as? UIPanGestureRecognizer else { return false }
            return pan.minimumNumberOfTouches == 2 && pan.isEnabled
        } ?? false)
    }

    private func setView(_ model: ReaderModel, _ surface: ScoreSurfaceView, scale: Double, x: Double, y: Double) -> PageViewport {
        var value = PageViewport(); value.scale = scale; value.offsetX = x; value.offsetY = y
        model.viewport = value; model.rememberViewport()
        surface.refresh(); surface.layoutIfNeeded()
        return value
    }

    func testZoomedPaperAndInkCanReachEveryWindowEdge() throws {
        let (model, surface) = try fixture()
        for size in [CGSize(width: 834, height: 1200), CGSize(width: 800, height: 1234),
                     CGSize(width: 1200, height: 834)] {
            surface.frame.size = size
            for mode in 0..<3 {
                if mode == 1 { model.enterPerformance() }
                if mode == 2 { model.exitPerformance(); model.beginAnnotation() }
                _ = setView(model, surface, scale: 3, x: 0, y: 0)
                let paper = try XCTUnwrap(model.canvas.superview?.subviews.compactMap { $0 as? PDFPaperView }.first)
                for content in [paper, model.canvas] {
                    var visible = content.convert(content.bounds, to: surface)
                    var ancestor = content.superview
                    while let view = ancestor {
                        if view.clipsToBounds {
                            visible = visible.intersection(view.convert(view.bounds, to: surface))
                        }
                        ancestor = view.superview
                    }
                    XCTAssertEqual(visible.minX, 0, accuracy: 0.01)
                    XCTAssertEqual(visible.minY, 0, accuracy: 0.01)
                    XCTAssertEqual(visible.maxX, size.width, accuracy: 0.01)
                    XCTAssertEqual(visible.maxY, size.height, accuracy: 0.01)
                }
            }
            XCTAssertTrue(model.saveAnnotation())
        }
    }

    func testEachPageRestoresItsOwnViewAfterTurnsSeekAndRelaunch() throws {
        let (model, surface) = try fixture()
        let first = setView(model, surface, scale: 2, x: 0.1, y: 0.2)
        let firstFrame = model.canvas.convert(model.canvas.bounds, to: surface)
        model.turn(forward: true); surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.viewport, PageViewport())
        let second = setView(model, surface, scale: 3, x: -0.4, y: 0.3)
        model.turn(forward: false); surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.viewport, first)
        XCTAssertEqual(model.canvas.convert(model.canvas.bounds, to: surface), firstFrame)
        model.seek(2); XCTAssertEqual(model.viewport, PageViewport())
        model.seek(1); XCTAssertEqual(model.viewport, second)
        model.flushDraft()
        let reopened = ReaderModel(store: LibraryStore(), session: model.session)
        XCTAssertEqual(reopened.viewport, second)
        reopened.seek(0); XCTAssertEqual(reopened.viewport, first)
        reopened.resetViewport(); reopened.flushDraft()
        XCTAssertEqual(reopened.viewport, PageViewport())
        reopened.seek(1); XCTAssertEqual(reopened.viewport, second)
    }

    func testPerformanceSharesSavedViewAndHalfTurnsUseNextPagesOwnView() throws {
        let (model, surface) = try fixture()
        let first = setView(model, surface, scale: 2, x: 0.1, y: 0.2)
        let beforePerformance = model.canvas.convert(model.canvas.bounds, to: surface)
        model.enterPerformance(); surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.viewport, first)
        XCTAssertEqual(model.canvas.convert(model.canvas.bounds, to: surface), beforePerformance)
        let changed = setView(model, surface, scale: 2.5, x: 0.2, y: 0.1)
        model.turn(forward: true)
        let second = setView(model, surface, scale: 3, x: -0.4, y: 0.3)
        model.turn(forward: false); XCTAssertEqual(model.viewport, changed)
        model.exitPerformance(); XCTAssertEqual(model.viewport, changed)
        XCTAssertTrue(model.store.update { $0.settings.halfPageTurns = true })
        model.refreshSettings(); model.turn(forward: true)
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertTrue(model.session.showingTransition)
        XCTAssertEqual(model.viewport, changed)
        model.turn(forward: true); surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.pageIndex, 1); XCTAssertEqual(model.viewport, second)
        XCTAssertEqual(model.canvas.convert(model.canvas.bounds, to: surface).width, 2400, accuracy: 1)
        model.flushDraft()
        let reopened = ReaderModel(store: LibraryStore(), session: model.session)
        XCTAssertEqual(reopened.viewport, second)
    }

    func testPinchKeepsFocalPointAndPanIsSavedOnBackgroundFlush() throws {
        let (model, surface) = try fixture()
        model.enterPerformance(); surface.refresh()
        let pinch = TestPinch()
        pinch.point = CGPoint(x: 100, y: 300); pinch.phase = .began; pinch.scale = 1
        surface.zoomPage(pinch)
        pinch.phase = .changed; pinch.scale = 2
        surface.zoomPage(pinch); surface.layoutIfNeeded()
        let focal = model.canvas.convert(CGPoint(x: 125, y: 375), to: surface)
        XCTAssertEqual(focal.x, 100, accuracy: 0.01); XCTAssertEqual(focal.y, 300, accuracy: 0.01)
        pinch.phase = .ended; surface.zoomPage(pinch)
        let pan = TestPan(); pan.phase = .began
        surface.movePage(pan)
        pan.phase = .changed; pan.delta = CGPoint(x: -80, y: 120)
        surface.movePage(pan); surface.layoutIfNeeded()
        let moved = model.canvas.convert(CGPoint(x: 125, y: 375), to: surface)
        XCTAssertEqual(moved.x, 20, accuracy: 0.01); XCTAssertEqual(moved.y, 420, accuracy: 0.01)
        // Lifecycle save must capture the live view, even before gesture-ended arrives.
        model.flushDraft()
        let saved = model.viewport
        let reopened = ReaderModel(store: LibraryStore(), session: model.session)
        XCTAssertEqual(reopened.viewport, saved)
        XCTAssertEqual(saved.scale, 2)
        XCTAssertEqual(saved.offsetX, 0.275, accuracy: 0.001)
        XCTAssertEqual(saved.offsetY, 0.35, accuracy: 0.001)
    }
}

private final class TestPinch: UIPinchGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
}

private final class TestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var delta = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { delta }
}
