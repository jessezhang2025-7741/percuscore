import XCTest
import PDFKit
import PencilKit
import QuartzCore
@testable import Percuscore

@MainActor
final class PageTurnPreviewTests: XCTestCase {
    func testInvalidatedInflightPageCanBeRequestedAgainBeforeItCompletes() async throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PausedPaperRenderer()
        let cache = PageTurnPreviewCache(renderer: gate)
        let key = PaperPreviewKey(scoreID: model.scoreID, page: 1)
        let request = PaperPreviewRequest(key: key, url: try XCTUnwrap(model.store.fileURL(model.scoreID)))
        cache.request([request], retaining: [key], delayNanoseconds: 0)
        for _ in 0..<300 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await gate.started
        XCTAssertTrue(started)
        cache.removeAll()
        cache.request([request], retaining: [key], delayNanoseconds: 0)
        await gate.release()
        try await waitFor(cache, key: key)
        assertColor(try XCTUnwrap(cache.preview(for: key)).image, red: 0, green: 0, blue: 1)
    }

    func testWarmNeighborUsesPDFOnlyUnderlayBeneathFreshSharpPaperAndLiveInk() async throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 200, y: 647), timeOffset: 0, size: CGSize(width: 200, height: 200), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
            PKStrokePoint(location: CGPoint(x: 800, y: 647), timeOffset: 1, size: CGSize(width: 200, height: 200), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        ], creationDate: Date()))])
        try model.store.disk!.writeInk(ink.dataRepresentation(), scoreID: model.scoreID, page: 1)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 834, height: 1194); surface.layoutIfNeeded()
        let oldPaper = try XCTUnwrap(views(surface).compactMap { $0 as? PDFPaperView }.first)
        try await Task.sleep(for: .milliseconds(450))
        model.turn(forward: true); surface.refresh(); surface.layoutIfNeeded()
        let preview = try XCTUnwrap(model.paperPreview)
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        assertColor(preview.image, red: 0, green: 0, blue: 1)
        let sharp = try XCTUnwrap(views(surface).compactMap { $0 as? PDFPaperView }.first)
        XCTAssertFalse(sharp === oldPaper); XCTAssertNil(oldPaper.superview)
        XCTAssertTrue(sharp.page === model.page)
        XCTAssertFalse(sharp.isOpaque)
        XCTAssertEqual(sharp.backgroundColor?.cgColor.alpha, 0)
        let image = try XCTUnwrap(views(surface).compactMap { $0 as? UIImageView }.first { $0.image === preview.image })
        XCTAssertTrue(image.superview === sharp.superview)
        XCTAssertTrue(image.superview === model.canvas.superview)
        let children = try XCTUnwrap(image.superview?.subviews)
        XCTAssertLessThan(try XCTUnwrap(children.firstIndex(of: image)), try XCTUnwrap(children.firstIndex(of: sharp)))
        XCTAssertLessThan(try XCTUnwrap(children.firstIndex(of: sharp)), try XCTUnwrap(children.firstIndex(of: model.canvas)))
        model.layout.rotation = 23; model.layout.scale = 1.3; model.viewport.offsetX = 0.08
        surface.refresh(); surface.layoutIfNeeded()
        for view in [sharp, model.canvas] {
            let expected = image.convert(CGPoint(x: 500, y: 647), to: surface)
            let actual = view.convert(CGPoint(x: 500, y: 647), to: surface)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.001); XCTAssertEqual(actual.y, expected.y, accuracy: 0.001)
        }
    }

    func testPixelBudgetAndRotatedPageGeometry() throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try XCTUnwrap(model.page); page.rotation = 90
        let image = try XCTUnwrap(PageRendering.paperPreview(page: page))
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertLessThanOrEqual(pixels.width * pixels.height, 1_048_576)
        XCTAssertGreaterThan(pixels.width, pixels.height)
        XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 792.0 / 612.0, accuracy: 0.005)
    }

    func testCacheEnforcesBytesCountAndLatestRequestedPages() async throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageTurnPreviewCache(byteLimit: 16 * 1024 * 1024, countLimit: 2)
        let url = try XCTUnwrap(model.store.fileURL(model.scoreID))
        let keys = (0..<4).map { PaperPreviewKey(scoreID: model.scoreID, page: $0) }
        cache.request([.init(key: keys[0], url: url), .init(key: keys[1], url: url)], retaining: Set(keys))
        try await waitFor(cache, key: keys[1])
        cache.request([.init(key: keys[2], url: url)], retaining: Set(keys))
        try await waitFor(cache, key: keys[2])
        XCTAssertEqual(cache.count, 2); XCTAssertNil(cache.preview(for: keys[0]))
        XCTAssertLessThanOrEqual(cache.retainedBytes, 16 * 1024 * 1024)
        cache.request([.init(key: keys[0], url: url)], retaining: [keys[0]], delayNanoseconds: 100_000_000)
        cache.request([.init(key: keys[3], url: url)], retaining: [keys[3]])
        try await waitFor(cache, key: keys[3])
        XCTAssertEqual(cache.count, 1); XCTAssertNil(cache.preview(for: keys[0]))
        assertColor(try XCTUnwrap(cache.preview(for: keys[3])).image, red: 1, green: 0.5, blue: 0)
    }

    func testTooSmallBudgetDoesNotRetainDecodedImageAndClearCanResume() async throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = PaperPreviewKey(scoreID: model.scoreID, page: 1)
        let request = PaperPreviewRequest(key: key, url: try XCTUnwrap(model.store.fileURL(model.scoreID)))
        let cache = PageTurnPreviewCache()
        cache.request([request], retaining: [key], delayNanoseconds: 100_000_000)
        cache.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.retainedBytes, 0)
        cache.request([request], retaining: [key]); try await waitFor(cache, key: key)
        let tooSmall = PageTurnPreviewCache(byteLimit: 1)
        tooSmall.request([request], retaining: [key])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(tooSmall.preview(for: key)); XCTAssertEqual(tooSmall.retainedBytes, 0)
    }

    func testMemoryWarningReleasesVisiblePreviewWithoutRefillOrInkLoss() async throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(400))
        model.turn(forward: true)
        XCTAssertNotNil(model.paperPreview)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        let drawing = model.canvas.drawing.dataRepresentation()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        surface.refresh()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.paperPreview)
        XCTAssertFalse(views(surface).compactMap { $0 as? UIImageView }.contains { $0.image != nil })
        XCTAssertEqual(model.canvas.drawing.dataRepresentation(), drawing)
        model.toggleInkVisibility()
        model.viewport.scale = 1.1; model.rememberViewport()
        model.orientationChanged(landscape: true); model.refreshSettings()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.seek(0))
        XCTAssertNil(model.paperPreview, "Nonnavigation actions after pressure must not have refilled the neighbor")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.seek(1))
        XCTAssertNotNil(model.paperPreview)
    }

    func testSamePageNumberInAnotherScoreCannotReuseOldPixels() async throws {
        let (model, root) = try fixture(colored: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageTurnPreviewCache()
        let first = PaperPreviewKey(scoreID: model.scoreID, page: 1)
        let second = PaperPreviewKey(scoreID: UUID(), page: 1)
        let url = try XCTUnwrap(model.store.fileURL(model.scoreID))
        cache.request([.init(key: first, url: url)], retaining: [first]); try await waitFor(cache, key: first)
        let other = root.appendingPathComponent("other.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: other) { context in
            for _ in 0..<2 { context.beginPage(); UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 612, height: 792)) }
        }
        cache.request([.init(key: second, url: other)], retaining: [second]); try await waitFor(cache, key: second)
        XCTAssertNil(cache.preview(for: first))
        assertColor(try XCTUnwrap(cache.preview(for: second)).image, red: 1, green: 0, blue: 0)
    }

    func testPaperTilesDoNotFadeDuringPageTurns() throws {
        let (model, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
        let paper = try XCTUnwrap(views(surface).first { $0 is PDFPaperView })
        let layerType = try XCTUnwrap(type(of: paper.layer) as? CATiledLayer.Type)
        XCTAssertEqual(layerType.fadeDuration(), 0, "Whole-page turns must not fade six separate tiles")
    }

    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }

    private func waitFor(_ cache: PageTurnPreviewCache, key: PaperPreviewKey) async throws {
        for _ in 0..<300 {
            if cache.preview(for: key) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected wanted page preview")
    }

    private func assertColor(_ image: UIImage, red: CGFloat, green: CGFloat, blue: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none; context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(CGFloat(rgba[0]) / 255, red, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(CGFloat(rgba[1]) / 255, green, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(CGFloat(rgba[2]) / 255, blue, accuracy: 0.02, file: file, line: line)
    }

    private func fixture(colored: Bool = false) throws -> (ReaderModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurnPreview-\(UUID())")
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Preview fixture", pageCount: 4)
        if colored {
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: disk.pdfURL(for: score.id)) { context in
                for color in [UIColor.green, .blue, .purple, .orange] {
                    context.beginPage(); color.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
                }
            }
        } else { try SampleScore.write(to: disk.pdfURL(for: score.id)) }
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings.halfPageTurns = false })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        return (ReaderModel(store: store, session: try XCTUnwrap(ReadingSession(queue: [item]))), root)
    }
}

/// Real PDF rendering with a controllable completion boundary, not fake pixels.
private actor PausedPaperRenderer: PaperPreviewRendering {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func release() { continuation?.resume(); continuation = nil }
    func render(_ request: PaperPreviewRequest) async throws -> PaperPreview? {
        let doc = try XCTUnwrap(PDFDocument(url: request.url))
        let page = try XCTUnwrap(doc.page(at: request.key.page))
        let image = try XCTUnwrap(PageRendering.paperPreview(page: page))
        let result = PaperPreview(image: image, canonicalSize: CGSize(width: 1000, height: 1294))
        if !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
}
