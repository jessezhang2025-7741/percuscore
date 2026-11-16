import Foundation
import CoreGraphics
import PencilKit
import AppKit

// Actual parser-readable assets for portable transport and reference tests.
enum BackupTestAssets {
    static func writePDF(to url: URL, pages: Int, padding: Int = 0) throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let attributes = padding > 0 ? [kCGPDFContextTitle: String(repeating: "A", count: padding)] as CFDictionary : nil
        guard let context = CGContext(url as CFURL, mediaBox: &box, attributes) else { throw CocoaError(.fileWriteUnknown) }
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
    }
    static let savedInk: Data = {
        let points = [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))]).dataRepresentation()
    }()
    static let draftInk = PKDrawing().dataRepresentation()
}
