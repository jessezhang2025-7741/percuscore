import XCTest
import PDFKit
import PencilKit
import AppKit
@testable import PercuscoreCore

final class PDFExportTests: XCTestCase {
    func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func source(at url: URL) throws {
        var bounds = CGRect(x: 20, y: 30, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 60, y: 530, width: 80, height: 20))
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 1)?.rotation = 90
        XCTAssertTrue(document.write(to: url))
    }
    func drawing() -> PKDrawing {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i), size: CGSize(width: 12, height: 12),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }
    func testOriginalIsExactCopyAndMarkedPreservesPagesAndSources() throws {
        let root = try folder(), disk = try LibraryDisk(root: root.appendingPathComponent("library"))
        let score = Score(title: "Practice", pageCount: 2)
        try source(at: disk.pdfURL(for: score.id))
        let ink = drawing().dataRepresentation()
        try disk.writeInk(ink, scoreID: score.id, page: 0)
        try disk.writeInk(ink, scoreID: score.id, page: 1)
        let original = try Data(contentsOf: disk.pdfURL(for: score.id))
        let copy = root.appendingPathComponent("original.pdf")
        try ScorePDFExport.write(score: score, disk: disk, includeMarkings: false, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        let output = root.appendingPathComponent("marked.pdf")
        try ScorePDFExport.write(score: score, disk: disk, includeMarkings: true, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 600))
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 600, height: 400))
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: score.id)), original)
        XCTAssertEqual(try disk.readInk(scoreID: score.id, page: 0), ink)
        for page in 0..<2 {
            let image = try XCTUnwrap(document.page(at: page)?.thumbnail(of: CGSize(width: 1000, height: 1500), for: .mediaBox))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var redPixels = 0
            var redX = 0.0, redY = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4 { redPixels += 1; redX += Double(x); redY += Double(y) }
                }
            }
            XCTAssertTrue(redPixels > 100)
            XCTAssertEqual(redX / Double(redPixels) / Double(bitmap.pixelsWide), 0.2, accuracy: 0.025)
            let expectedY = page == 0 ? 100.0 / 1500 : 100.0 / (1000 * 400 / 600)
            XCTAssertEqual(redY / Double(redPixels) / Double(bitmap.pixelsHigh), expectedY, accuracy: 0.025)
            if let directory = ProcessInfo.processInfo.environment["PERCUSCORE_PDF_QA"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("marked-\(page).png"))
                try Data(contentsOf: output).write(to: url.appendingPathComponent("marked.pdf"))
            }
        }
    }
    func testCorruptInkFailsWithoutPublishingPartialPDF() throws {
        let root = try folder(), disk = try LibraryDisk(root: root.appendingPathComponent("library"))
        let score = Score(title: "Practice", pageCount: 2)
        try source(at: disk.pdfURL(for: score.id))
        try disk.writeInk(Data([0,1,2]), scoreID: score.id, page: 1)
        let output = root.appendingPathComponent("marked.pdf")
        XCTAssertThrowsError(try ScorePDFExport.write(score: score, disk: disk, includeMarkings: true, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
