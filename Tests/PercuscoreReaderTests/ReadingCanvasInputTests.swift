import XCTest
import UIKit
import PencilKit
@testable import Percuscore

@MainActor
final class ReadingCanvasInputTests: XCTestCase {
    private func fixture() throws -> (ReaderModel, ScoreSurfaceView) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingInput-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Reading input", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score] })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        let model = ReaderModel(store: store, session: try XCTUnwrap(ReadingSession(queue: [item])))
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        surface.layoutIfNeeded()
        return (model, surface)
    }

    func testReadingCanvasDoesNotCaptureNavigationHitTests() throws {
        let (model, _) = try fixture()
        XCTAssertEqual(model.mode, .reading)
        XCTAssertFalse(model.canvas.isHidden)
        XCTAssertNil(model.canvas.hitTest(CGPoint(x: 400, y: 500), with: nil),
                     "A reading canvas must not capture navigation or selection touches without Pencil input")
    }

    func testDoneReturnsCanvasToDisplayOnlyAndPreservesSavedInk() throws {
        let (model, _) = try fixture()
        model.beginAnnotation()
        let points = [CGPoint(x: 200, y: 500), CGPoint(x: 400, y: 500)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 10, height: 10),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        model.canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        XCTAssertNotNil(model.canvas.hitTest(CGPoint(x: 300, y: 500), with: nil))
        XCTAssertTrue(model.saveAnnotation())
        XCTAssertNil(model.canvas.hitTest(CGPoint(x: 300, y: 500), with: nil))
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        let reopened = ReaderModel(store: model.store, session: model.session)
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 1)
    }

    func testReadingRoutesFingerTouchesAwayAndRetainsPencilAutoAnnotation() throws {
        let (model, _) = try fixture()
        let pen = CGPoint(x: 400, y: 500), finger = CGPoint(x: 100, y: 100)
        XCTAssertFalse(model.canvas.acceptsInput(at: finger, contacts: [(.direct, finger)]))
        XCTAssertFalse(model.canvas.acceptsInput(at: pen, contacts: [(.direct, finger), (.direct, pen)]))
        XCTAssertFalse(model.canvas.acceptsInput(at: pen, contacts: [(.indirectPointer, pen)]))
        let mixed: [(type: UITouch.TouchType, location: CGPoint)] = [(.direct, finger), (.pencil, pen)]
        XCTAssertTrue(model.canvas.acceptsInput(at: pen, contacts: mixed), "A finger elsewhere must not block Pencil auto-entry")
        XCTAssertFalse(model.canvas.acceptsInput(at: finger, contacts: mixed), "A Pencil elsewhere must not enable finger selection")
        XCTAssertTrue(model.canvas.acceptsInput(at: pen, contacts: [(.pencil, CGPoint(x: 400.1, y: 500.1))]))
        model.canvasViewDidBeginUsingTool(model.canvas)
        XCTAssertEqual(model.mode, .annotating)
        XCTAssertTrue(model.canvas.acceptsInput(at: finger, contacts: [(.direct, finger)]))
        XCTAssertTrue(model.canvas.acceptsInput(at: pen, contacts: [(.pencil, pen)]))
        XCTAssertEqual(model.canvas.drawingPolicy, .pencilOnly, "Finger selection in markup must not enable finger drawing")
        XCTAssertTrue(model.saveAnnotation())
        XCTAssertFalse(model.canvas.acceptsInput(at: finger, contacts: [(.direct, finger)]))
    }

    func testDisabledAutoAnnotationPerformanceAndCropCannotCaptureCanvasInput() throws {
        let (model, _) = try fixture()
        XCTAssertTrue(model.store.update { $0.settings.pencilAutoAnnotate = false })
        model.refreshSettings()
        let point = CGPoint(x: 400, y: 500)
        XCTAssertFalse(model.canvas.acceptsInput(at: point, contacts: [(.pencil, point)]))
        model.beginAnnotation()
        XCTAssertTrue(model.canvas.acceptsInput(at: point, contacts: [(.pencil, point)]))
        XCTAssertTrue(model.canvas.acceptsInput(at: point, contacts: [(.direct, point)]))
        XCTAssertTrue(model.saveAnnotation())
        model.enterPerformance()
        XCTAssertFalse(model.canvas.acceptsInput(at: point, contacts: [(.direct, point)]))
        XCTAssertFalse(model.canvas.acceptsInput(at: point, contacts: [(.pencil, point)]))
        model.exitPerformance(); model.beginCrop()
        XCTAssertFalse(model.canvas.acceptsInput(at: point, contacts: [(.direct, point)]))
        XCTAssertFalse(model.canvas.acceptsInput(at: point, contacts: [(.pencil, point)]))
    }
}
