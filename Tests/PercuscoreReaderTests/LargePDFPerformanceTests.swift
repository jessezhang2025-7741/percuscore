import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor final class LargePDFPerformanceTests: XCTestCase {
    private func fixture(half: Bool = false) throws -> ReaderModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let score = Score(title: "Preview lifecycle", pageCount: 60)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: store.disk!.pdfURL(for: score.id)) { context in
            for page in 0..<60 {
                context.beginPage(); UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 40 + page, y: 60, width: 200, height: 500))
            }
        }
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings.halfPageTurns = half })
        return ReaderModel(store: store, session: ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 59)])!)
    }
    private func waitForPreview(_ model: ReaderModel) async throws {
        for _ in 0..<200 {
            if model.transitionImage(next: false) != nil, model.transitionImage(next: true) != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Half-page previews did not arrive")
    }
    func testOrdinaryReadingDoesNotAllocateHalfPagePreviews() async throws {
        let model = try fixture()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(model.transitionImage(next: false), "Full-page reading must not allocate unused transition rasters")
        XCTAssertNil(model.transitionImage(next: true))
    }
    func testBurstTurnRejectsStalePreview() async throws {
        let model = try fixture(half: true)
        for _ in 0..<80 { model.turn(forward: true) }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.pageIndex, 40)
        XCTAssertEqual(model.page?.document?.index(for: model.page!), 40)
        model.turn(forward: true)
        XCTAssertTrue(model.session.showingTransition)
        try await waitForPreview(model)
        XCTAssertEqual(model.pageIndex, 40)
        let expected = PageRendering.image(page: model.page!, drawing: model.canvas.drawing, layout: model.viewport.applying(to: model.layout))
        XCTAssertEqual(model.transitionImage(next: false)?.pngData(), expected.pngData())
    }
    func testHalfTurnUncachedStillAdvances() throws {
        let model = try fixture(half: true)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 834, height: 1100)
        model.turn(forward: true); surface.refresh(); surface.layoutIfNeeded()
        XCTAssertTrue(model.session.showingTransition); XCTAssertEqual(model.pageIndex, 0)
        model.turn(forward: true); XCTAssertFalse(model.session.showingTransition); XCTAssertEqual(model.pageIndex, 1)
    }
    func testMemoryPressureReleasesPreviewsButRetainsInk() async throws {
        let model = try fixture(half: true)
        let points = [CGPoint(x: 50, y: 80), CGPoint(x: 300, y: 80)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        }
        model.canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let ink = model.canvas.drawing.dataRepresentation()
        try await waitForPreview(model)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(model.transitionImage(next: false)); XCTAssertNil(model.transitionImage(next: true))
        XCTAssertEqual(model.canvas.drawing.dataRepresentation(), ink)
        model.turn(forward: true); XCTAssertTrue(model.session.showingTransition)
        try await waitForPreview(model)
    }
    func testMarkedCropViewportStableAfterEviction() async throws {
        let model = try fixture(half: true)
        model.beginCrop(); model.layout.scale = 1.3; model.layout.rotation = 2; model.saveCrop()
        model.viewport.scale = 2; model.viewport.offsetX = 0.1; model.rememberViewport()
        let stroke = PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 80, y: 90), timeOffset: 0, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
            PKStrokePoint(location: CGPoint(x: 300, y: 90), timeOffset: 1, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        ], creationDate: Date()))
        model.beginAnnotation()
        model.canvas.drawing = PKDrawing(strokes: [stroke])
        XCTAssertTrue(model.saveAnnotation())
        let markedImage = PageRendering.image(page: model.page!, drawing: model.canvas.drawing, layout: model.viewport.applying(to: model.layout)).pngData()
        let layout = model.layout, viewport = model.viewport
        try await waitForPreview(model)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        model.flushDraft()
        let reopened = ReaderModel(store: LibraryStore(root: model.store.disk!.root), session: model.session)
        XCTAssertEqual(reopened.layout, layout); XCTAssertEqual(reopened.viewport, viewport)
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(PageRendering.image(page: reopened.page!, drawing: reopened.canvas.drawing, layout: reopened.viewport.applying(to: reopened.layout)).pngData(), markedImage)
    }
    func testCompletedHalfTurnReleasesDisplayedPreview() async throws {
        let model = try fixture(half: true)
        try await waitForPreview(model)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        weak var preview: UIImage?
        autoreleasepool {
            model.turn(forward: true); surface.refresh()
            preview = model.transitionImage(next: false)
            XCTAssertNotNil(preview)
            model.turn(forward: true); surface.refresh()
            _ = model.store.update { $0.settings.halfPageTurns = false }
            model.refreshSettings(); surface.refresh()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(preview, "Completed transitions must release hidden raster views")
        withExtendedLifetime(surface) {}
    }
    func testUnreadableDestinationKeepsCurrentPage() throws {
        let model = try fixture()
        let missing = ReadingItem(scoreID: UUID(), title: "Missing PDF", startPage: 0, endPage: 0)
        model.session = ReadingSession(queue: [model.session.item, missing], page: 59)!
        model.loadCurrentPage(); let page = model.page
        model.turn(forward: true)
        XCTAssertEqual(model.pageIndex, 59); XCTAssertTrue(model.page === page); XCTAssertNotNil(model.errorMessage)
    }
}
