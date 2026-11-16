import Foundation
import PDFKit
import PencilKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Flattens a *copy*. The original PDF and canonical 1000-point-wide PKDrawing files are read only.
public enum ScorePDFExport {
    public static func write(score: Score, disk: LibraryDisk, includeMarkings: Bool, to destination: URL) throws {
        let source = disk.pdfURL(for: score.id)
        if !includeMarkings {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard let document = PDFDocument(url: source), !document.isLocked,
              document.pageCount > 0, document.pageCount == score.pageCount else { throw LibraryError.invalidPDF }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let output = CGContext(temporary as CFURL, mediaBox: nil,
                                     [kCGPDFContextTitle: score.title] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        var closed = false
        defer { if !closed { output.closePDF() } }
        for number in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: number), let reference = page.pageRef else { throw LibraryError.invalidPDF }
                let box = reference.getBoxRect(.mediaBox)
                let rotated = abs(page.rotation) % 180 == 90
                let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw LibraryError.invalidPDF }
                var bounds = CGRect(origin: .zero, size: size)
                let boxData = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
                output.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                output.setFillColor(CGColor(gray: 1, alpha: 1)); output.fill(bounds)
                output.saveGState()
                output.concatenate(reference.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
                output.drawPDFPage(reference)
                for annotation in page.annotations where annotation.shouldDisplay {
                    annotation.draw(with: .mediaBox, in: output)
                }
                output.restoreGState()
                if let data = try disk.readInk(scoreID: score.id, page: number) {
                    let drawing = try PKDrawing(data: data)
                    if !drawing.strokes.isEmpty {
                        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 1000 * size.height / size.width)
                        // Preserve vector score content, bound only the transparent ink bitmap memory.
                        let scale = min(2, 4096 / max(canvas.width, canvas.height))
                        let image = drawing.image(from: canvas, scale: scale)
                        #if canImport(UIKit)
                        guard let cgImage = image.cgImage else { throw CocoaError(.fileWriteUnknown) }
                        #else
                        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
                        #endif
                        output.draw(cgImage, in: bounds)
                    }
                }
                output.endPDFPage()
            }
        }
        output.closePDF(); closed = true
        guard let verified = PDFDocument(url: temporary), verified.pageCount == document.pageCount else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
