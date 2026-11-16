import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class ReaderInkTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ReadingSession) {
        let store = LibraryStore()
        let disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Ink isolation", pageCount: 3)
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600), format: format)
        try renderer.writePDF(to: disk.pdfURL(for: score.id)) { context in
            for page in 0..<3 {
                context.beginPage()
                "Page \(page + 1)".draw(at: CGPoint(x: 100, y: 100), withAttributes: [.foregroundColor: UIColor.black])
            }
        }
        XCTAssertTrue(store.update { index in
            index.scores = [score]
            index.settings.halfPageTurns = true
        })
        let session = try XCTUnwrap(ReadingSession(queue: [ReadingItem(scoreID: score.id, title: score.title, startPage: 0, endPage: 2)]))
        return (store, session)
    }

    private func drawing(y: CGFloat) -> PKDrawing {
        // Reader ink uses a 1000×1500 canonical page for this 400×600 PDF.
        // y=1000 is inside its lower half, where half-turn ink must remain visible.
        let points = [CGPoint(x: 100, y: y), CGPoint(x: 300, y: y)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 12, height: 12),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    func testHalfTurnsDoNotCarrySavedInkOntoBlankPages() throws {
        let (store, session) = try fixture()
        let model = ReaderModel(store: store, session: session)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        model.beginAnnotation()
        model.canvas.drawing = drawing(y: 1000)
        XCTAssertTrue(model.saveAnnotation())
        model.turn(forward: true)
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertTrue(model.session.showingTransition)
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        model.turn(forward: true)
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        model.beginAnnotation()
        XCTAssertTrue(model.saveAnnotation())
        let disk = try XCTUnwrap(store.disk)
        let saved = try XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 1))
        XCTAssertTrue(try PKDrawing(data: saved).strokes.isEmpty)
        let reopened = ReaderModel(store: store, session: model.session)
        XCTAssertTrue(reopened.canvas.drawing.strokes.isEmpty)
        model.turn(forward: false)
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.pageIndex, 0)
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        XCTAssertTrue(model.session.showingTransition)
    }

    func testAnnotationArrowsSaveOnlyThePageBeingEdited() throws {
        let (store, session) = try fixture()
        let model = ReaderModel(store: store, session: session)
        model.beginAnnotation()
        model.canvas.drawing = drawing(y: 100)
        model.turn(forward: true, annotationArrow: true)
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        model.canvas.drawing = drawing(y: 500)
        model.turn(forward: true, annotationArrow: true)
        XCTAssertEqual(model.pageIndex, 2)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        XCTAssertTrue(model.saveAnnotation())
        let disk = try XCTUnwrap(store.disk)
        let first = try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 0)))
        let second = try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 1)))
        XCTAssertEqual(first.strokes.count, 1)
        XCTAssertEqual(second.strokes.count, 1)
        XCTAssertNotEqual(first.bounds, second.bounds)
    }

    func testOutgoingCanvasCannotChangeOrSaveInkOnTheNextPage() throws {
        let (store, session) = try fixture()
        let model = ReaderModel(store: store, session: session)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        model.beginAnnotation()
        let outgoingCanvas = model.canvas
        outgoingCanvas.drawing = drawing(y: 1000)
        model.turn(forward: true, annotationArrow: true)
        surface.refresh(); surface.layoutIfNeeded()
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertNil(outgoingCanvas.superview)
        XCTAssertTrue(model.canvas.isDescendant(of: surface))
        // A queued PencilKit update/undo from the outgoing view must stay on that page.
        outgoingCanvas.drawing = drawing(y: 1000)
        model.canvasViewDrawingDidChange(outgoingCanvas)
        model.canvasViewDidEndUsingTool(outgoingCanvas)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        XCTAssertTrue(model.saveAnnotation())
        let disk = try XCTUnwrap(store.disk)
        let saved = try XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 1))
        XCTAssertTrue(try PKDrawing(data: saved).strokes.isEmpty)
        let reopened = ReaderModel(store: store, session: model.session)
        XCTAssertTrue(reopened.canvas.drawing.strokes.isEmpty)
    }

    func testOldToolCallbacksCannotEnterAnnotationOrCreateDraftOnNewPage() throws {
        let (store, session) = try fixture()
        let model = ReaderModel(store: store, session: session)
        let outgoingCanvas = model.canvas
        model.turn(forward: true)
        model.turn(forward: true)
        XCTAssertEqual(model.pageIndex, 1)
        outgoingCanvas.drawing = drawing(y: 1000)
        model.canvasViewDidBeginUsingTool(outgoingCanvas)
        model.canvasViewDrawingDidChange(outgoingCanvas)
        model.canvasViewDidEndUsingTool(outgoingCanvas)
        XCTAssertEqual(model.mode, .reading)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        XCTAssertNil(try store.disk?.readInk(scoreID: model.scoreID, page: 1, draft: true))
    }
}
