import Foundation
import UIKit
import PDFKit
import PencilKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct AcceptanceFixtureManifest: Codable {
    let generator: String
    let scanPages: Int
    let scanDPI: Int
    let pdfSHA256: [String: String]
    let initialInkSHA256: String
}

enum AcceptanceFixtures {
    static let scoreIDs = (1...4).map { UUID(uuidString: String(format: "ACCE0000-0000-4000-8000-%012d", $0))! }
    static let setlistID = UUID(uuidString: "ACCE0000-0000-4000-9000-000000000001")!
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func build(at root: URL, scanPages: Int = 120, dpi: Int = 300,
                      progress: @Sendable (Int) -> Void = { _ in }) throws -> AcceptanceFixtureManifest {
        guard (1...120).contains(scanPages), (72...300).contains(dpi) else { throw LibraryError.invalidPDF }
        let disk = try LibraryDisk(root: root)
        var scores = zip(scoreIDs, ["01 · Four-page Pencil practice", "02 · Rotated pages", "03 · Crop and saved ink", "04 · Large scanned practice"]).map {
            Score(id: $0.0, title: $0.1, pageCount: $0.0 == scoreIDs[3] ? scanPages : 4)
        }
        for score in scores.prefix(3) { try SampleScore.write(to: disk.pdfURL(for: score.id)) }
        let rotated = PDFDocument(url: disk.pdfURL(for: scoreIDs[1]))!
        for page in 0..<4 { rotated.page(at: page)!.rotation = page * 90 }
        guard rotated.write(to: disk.pdfURL(for: scoreIDs[1])) else { throw LibraryError.invalidPDF }
        var crop = PageLayout(); crop.scale = 1.15; crop.offsetX = 0.025
        scores[2].layouts[0] = crop
        let points = [CGPoint(x: 150, y: 400), CGPoint(x: 600, y: 420)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i), size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
        try disk.writeInk(ink.dataRepresentation(), scoreID: scoreIDs[2], page: 0)
        try scannedPDF(to: disk.pdfURL(for: scoreIDs[3]), pages: scanPages, dpi: dpi, progress: progress)
        try Task.checkCancellation()
        var index = LibraryIndex(); index.scores = scores
        var setlist = ScoreSetlist(id: setlistID, title: "Acceptance · Cross-work rehearsal")
        setlist.entries = scores.map { SetlistEntry(scoreID: $0.id) }; index.setlists = [setlist]
        index.settings.preventFingerDrawing = true
        let hashes = try Dictionary(uniqueKeysWithValues: scores.map { ($0.id.uuidString, try sha256(disk.pdfURL(for: $0.id))) })
        let manifest = AcceptanceFixtureManifest(generator: "percuscore-device-fixtures-v1", scanPages: scanPages, scanDPI: dpi,
                                                 pdfSHA256: hashes, initialInkSHA256: try sha256(disk.inkURL(scoreIDs[2], page: 0)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        try disk.save(index) // Assets and manifest must be complete before the index is published.
        return manifest
    }
    static func verify(at root: URL) throws -> AcceptanceFixtureManifest {
        let data = try LibraryDisk.readBounded(root.appendingPathComponent("manifest.json"), maximumBytes: 64 * 1024)
        let manifest = try JSONDecoder().decode(AcceptanceFixtureManifest.self, from: data)
        guard manifest.generator == "percuscore-device-fixtures-v1",
              Set(manifest.pdfSHA256.keys) == Set(scoreIDs.map(\.uuidString)) else { throw LibraryError.corruptIndex }
        let disk = try LibraryDisk(root: root), index = try disk.load()
        guard Set(index.scores.map(\.id)) == Set(scoreIDs), index.setlists.contains(where: { $0.id == setlistID }) else { throw LibraryError.corruptIndex }
        for id in scoreIDs {
            guard try sha256(disk.pdfURL(for: id)) == manifest.pdfSHA256[id.uuidString] else { throw LibraryError.invalidPDF }
        }
        return manifest
    }
    private static func scannedPDF(to url: URL, pages: Int, dpi: Int, progress: @Sendable (Int) -> Void) throws {
        let width = Int(8.5 * Double(dpi)), height = 11 * dpi
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw LibraryError.invalidPDF }
        defer { pdf.closePDF() }
        for page in 0..<pages {
            try Task.checkCancellation()
            try autoreleasepool {
                let gray = page % 2 == 0, components = gray ? 1 : 4
                let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * components)
                defer { bytes.deallocate() }
                var random = UInt64(20261008 + page * 7919)
                for p in 0..<(width * height) {
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    let noise = UInt8((random >> 56) % 13)
                    if gray { bytes[p] = 255 - noise }
                    else { bytes[p*4] = 255-noise; bytes[p*4+1] = 251-noise; bytes[p*4+2] = 244-noise; bytes[p*4+3] = 255 }
                }
                guard let bitmap = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * components, space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) else { throw LibraryError.invalidPDF }
                bitmap.scaleBy(x: CGFloat(width)/612, y: CGFloat(height)/792)
                bitmap.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); bitmap.setFillColor(CGColor(gray: 0.1, alpha: 1))
                bitmap.setLineWidth(0.7)
                for row in 0..<11 {
                    let y = CGFloat(100 + row * 54)
                    for staff in 0..<5 { bitmap.move(to: CGPoint(x: 42, y: y + CGFloat(staff*5))); bitmap.addLine(to: CGPoint(x: 570, y: y + CGFloat(staff*5))); bitmap.strokePath() }
                    for note in 0..<18 {
                        let x = CGFloat(52 + note*29), yy = y + CGFloat((note+page+row)%5*5)
                        bitmap.fillEllipse(in: CGRect(x: x, y: yy-3, width: 9, height: 6))
                        bitmap.move(to: CGPoint(x: x+8, y: yy)); bitmap.addLine(to: CGPoint(x: x+8, y: yy+24)); bitmap.strokePath()
                    }
                }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
                      let image = bitmap.makeImage() else { throw LibraryError.invalidPDF }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary)
                guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data),
                      let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw LibraryError.invalidPDF }
                pdf.beginPDFPage(nil); pdf.draw(jpeg, in: box); pdf.endPDFPage()
            }
            progress(page + 1)
        }
    }
}
