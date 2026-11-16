import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class PreviewBoundsTests: XCTestCase {
    private func page(width: CGFloat, height: CGFloat) throws -> PDFPage {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height))
            .pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data: data))
        return try XCTUnwrap(document.page(at: 0))
    }

    func testTallPreviewBitmapIsBoundedBeforeCaching() throws {
        // Old code requests 18 million pixels here, far below the audit's 9 GB case.
        let source = try page(width: 10, height: 80)
        let image = try XCTUnwrap(PageRendering.image(page: source, drawing: PKDrawing(), layout: PageLayout()).cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 4096)
        XCTAssertLessThanOrEqual(image.width * image.height, 4_194_304)
        XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, 17 * 1024 * 1024)
    }

    private func drawing(in size: CGSize) -> PKDrawing {
        let points = [CGPoint(x: size.width * 0.4, y: size.height * 0.5),
                      CGPoint(x: size.width * 0.6, y: size.height * 0.5)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset),
                          size: CGSize(width: 30, height: 30), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    func testAuditPDFAndRotatedWidePDFRenderWithInkWithinBudget() throws {
        for rotation in [0, 90] {
            let source = try page(width: 10, height: 10000)
            source.rotation = rotation
            let canonical = PageRendering.size(of: source)
            let ink = drawing(in: canonical), before = ink.dataRepresentation()
            let image = try XCTUnwrap(PageRendering.image(page: source, drawing: ink, layout: PageLayout()).cgImage)
            XCTAssertLessThanOrEqual(max(image.width, image.height), 4096)
            XCTAssertLessThanOrEqual(image.width * image.height, 4_194_304)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, 17 * 1024 * 1024)
            XCTAssertEqual(ink.dataRepresentation(), before, "Preview downsampling must not rewrite canonical ink")
            XCTAssertEqual(PageRendering.size(of: source), canonical)
            print("BOUNDED PREVIEW rotation=\(rotation) pixels=\(image.width)x\(image.height) bytes=\(image.bytesPerRow * image.height)")
        }
    }

    func testCommonScoreKeepsResolutionAndCropInkAlignment() throws {
        let source = try page(width: 612, height: 792)
        var layout = PageLayout(); layout.scale = 1.3; layout.offsetX = 0.05
        let image = try XCTUnwrap(PageRendering.image(page: source, drawing: drawing(in: PageRendering.size(of: source)), layout: layout).cgImage)
        XCTAssertEqual(image.width, 1500, "Ordinary scores retain the existing 1.5x horizontal resolution")
        XCTAssertGreaterThanOrEqual(image.height, 1940)
        XCTAssertLessThanOrEqual(image.height, 1942)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var count = 0, xSum = 0.0, ySum = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if Int(rgba[i]) > 140 && Int(rgba[i]) > Int(rgba[i + 1]) + 60 && Int(rgba[i]) > Int(rgba[i + 2]) + 60 {
                    count += 1; xSum += Double(x); ySum += Double(y)
                }
            }
        }
        XCTAssertGreaterThan(count, 0, "The downsampled composite must contain the saved ink")
        guard count > 0 else { return }
        XCTAssertEqual(xSum / Double(count) / Double(image.width), 0.55, accuracy: 0.02)
        XCTAssertEqual(ySum / Double(count) / Double(image.height), 0.5, accuracy: 0.02)
    }

    func testGeometryRejectsInvalidDimensionsAndBoundsHugeFiniteValues() throws {
        for size in [CGSize(width: 0, height: 1), CGSize(width: 1, height: -1),
                     CGSize(width: CGFloat.nan, height: 1), CGSize(width: 1, height: CGFloat.infinity),
                     CGSize(width: 1000, height: CGFloat.leastNonzeroMagnitude)] {
            XCTAssertNil(PageRendering.previewPixelSize(for: size))
        }
        for size in [CGSize(width: 1000, height: 1_000_000), CGSize(width: 1000, height: 1_000_000_000_000),
                     CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                     CGSize(width: 1000, height: 1000)] {
            let pixels = try XCTUnwrap(PageRendering.previewPixelSize(for: size))
            XCTAssertGreaterThanOrEqual(min(pixels.width, pixels.height), 1)
            XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 4096)
            XCTAssertLessThanOrEqual(pixels.width * pixels.height, 4_194_304)
        }
    }

    func testNextHalfPreviewKeepsPageAspectAfterPixelRounding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let score = Score(title: "Thin next page", pageCount: 2)
        let disk = try XCTUnwrap(store.disk)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            .writePDF(to: disk.pdfURL(for: score.id)) { context in
                context.beginPage()
                context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 1, height: 8192), pageInfo: [:])
            }
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings.halfPageTurns = true })
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 1)]))
        let model = ReaderModel(store: store, session: session)
        for _ in 0..<200 {
            if model.transitionImage(next: true) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let image = try XCTUnwrap(model.transitionImage(next: true))
        XCTAssertEqual(image.cgImage?.width, 1)
        XCTAssertEqual(image.cgImage?.height, 4096)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 834, height: 1100)
        model.turn(forward: true); surface.refresh(); surface.layoutIfNeeded()
        func imageView(in view: UIView) -> UIImageView? {
            if let view = view as? UIImageView, view.image === image { return view }
            return view.subviews.lazy.compactMap { imageView(in: $0) }.first
        }
        let preview = try XCTUnwrap(imageView(in: surface))
        XCTAssertEqual(preview.frame.height / preview.frame.width, 8192, accuracy: 0.01,
                       "Integer preview pixels must not distort the next page's display aspect")
    }
}
