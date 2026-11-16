import XCTest
import PDFKit
import PencilKit
import AppKit
import CryptoKit
@testable import PercuscoreCore

final class BackupContentTests: XCTestCase {
    private func disk() throws -> LibraryDisk {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupContent-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LibraryDisk(root: root)
    }
    private func pdf(pages: Int = 1, width: Double = 600, height: Double = 800) throws -> Data {
        let root = try disk(), url = root.root.appendingPathComponent("fixture.pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return try Data(contentsOf: url)
    }
    private func drawing(points count: Int = 2) -> Data {
        let points = (0..<count).map { i in
            PKStrokePoint(location: CGPoint(x: i % 500, y: i % 700), timeOffset: Double(i) / 100,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        return PKDrawing(strokes: [stroke]).dataRepresentation()
    }
    // Build the actual v1 format independently, including valid SHA-256 for arbitrary asset bytes.
    private func archive(index: LibraryIndex, assets: [(UUID, String, Int?, Data, UInt64?)]) throws -> URL {
        let root = try disk(), url = root.root.appendingPathComponent("input.percuscorebackup")
        var indexObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as? [String: Any])
        indexObject["version"] = 1
        let assetObjects: [[String: Any]] = assets.map { id, kind, page, data, declared in
            var result: [String: Any] = ["scoreID": id.uuidString, "kind": kind,
                "count": declared ?? UInt64(data.count), "digest": Data(SHA256.hash(data: data)).base64EncodedString()]
            if let page { result["page"] = page }
            return result
        }
        let header = try JSONSerialization.data(withJSONObject: ["version": 1, "createdAt": 0,
            "index": indexObject, "assets": assetObjects])
        var bytes = Data("PERCUB01".utf8), length = UInt64(header.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(Data(SHA256.hash(data: header))); bytes.append(header)
        for asset in assets { bytes.append(asset.3) }
        try bytes.write(to: url); return url
    }
    private func index(pages: Int = 1) -> LibraryIndex {
        var index = LibraryIndex(); index.scores = [Score(title: "Incoming", pageCount: pages)]; return index
    }
    private func assertRejected(_ archive: URL, limit: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let target = try disk(); var current = index()
        current.scores[0].title = "Existing"
        try pdf().write(to: target.pdfURL(for: current.scores[0].id)); try target.save(current)
        let originalArchive = try Data(contentsOf: archive)
        let originalIndex = try Data(contentsOf: target.root.appendingPathComponent("library.json"))
        let originalPDF = try Data(contentsOf: target.pdfURL(for: current.scores[0].id))
        XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: target, current: current), file: file, line: line) {
            if limit { XCTAssertTrue($0.localizedDescription.lowercased().contains("limit"), "\($0)", file: file, line: line) }
        }
        XCTAssertEqual(try target.load(), current, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("library.json")), originalIndex, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: target.pdfURL(for: current.scores[0].id)), originalPDF, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.pdfDirectory.path).count, 1, file: file, line: line)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.inkDirectory.path).isEmpty, file: file, line: line)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.recoveryDirectory.path).isEmpty, file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.root.path).contains { $0.hasPrefix(".restore-") }, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive, file: file, line: line)
    }
    func testCorrectChecksumCannotMakeNonPDFReadable() throws {
        let index = index(), id = index.scores[0].id
        try assertRejected(archive(index: index, assets: [(id, "pdf", nil, Data("not PDF".utf8), nil)]))
    }
    func testActualPageCountMustMatchDeclaredCount() throws {
        let index = index(pages: 2), id = index.scores[0].id
        try assertRejected(archive(index: index, assets: [(id, "pdf", nil, try pdf(), nil)]))
    }
    func testLockedPDFIsRejectedAndArchivePreserved() throws {
        let index = index(), id = index.scores[0].id, root = try disk()
        let doc = try XCTUnwrap(PDFDocument(data: pdf()))
        let url = root.root.appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).isLocked)
        try assertRejected(archive(index: index, assets: [(id, "pdf", nil, try Data(contentsOf: url), nil)]))
    }
    func testInvalidOrExtremePageGeometryIsRejected() throws {
        let index = index(), id = index.scores[0].id
        for (width, height) in [(0.0, 800.0), (15001.0, 800.0), (1.0, 2000.0)] {
            try assertRejected(archive(index: index, assets: [(id, "pdf", nil, try pdf(width: width, height: height), nil)]))
        }
    }
    func testBadConfirmedAndDraftDrawingPreventAllAssetInstallation() throws {
        let index = index(), id = index.scores[0].id
        for kind in ["ink", "draft"] {
            try assertRejected(archive(index: index, assets: [(id, "pdf", nil, try pdf(), nil),
                (id, kind, 0, Data("invalid drawing".utf8), nil)]))
        }
    }
    func testOversizedAssetDeclarationsAndUInt64MaxFailWithLimitError() throws {
        let index = index(), id = index.scores[0].id
        for count in [UInt64(512 * 1024 * 1024 + 1), UInt64.max] {
            try assertRejected(archive(index: index, assets: [(id, "pdf", nil, Data(), count)]), limit: true)
        }
        try assertRejected(archive(index: index, assets: [(id, "pdf", nil, try pdf(), nil),
            (id, "ink", 0, Data(), UInt64(16 * 1024 * 1024 + 1))]), limit: true)
    }
    func testTotalAssetBudgetCheckedBeforeStagingPayload() throws {
        var index = LibraryIndex(); index.scores = (0..<8).map { Score(title: "Score \($0)", pageCount: 1) }
        let assets = index.scores.map { ($0.id, "pdf", Optional<Int>.none, Data(), Optional(UInt64(300 * 1024 * 1024))) }
        try assertRejected(archive(index: index, assets: assets), limit: true)
    }
    func testDeclaredPageBudgetCheckedBeforeParsingPDF() throws {
        let index = index(pages: 5001), id = index.scores[0].id
        try assertRejected(archive(index: index, assets: [(id, "pdf", nil, Data(), UInt64(1))]), limit: true)
    }
    func testOversizedLocalInkReadAndWriteAreBounded() throws {
        let disk = try disk(), id = UUID()
        for draft in [false, true] {
            let url = disk.inkURL(id, page: 0, draft: draft)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(17 * 1024 * 1024 + 1)); try handle.close()
            XCTAssertThrowsError(try disk.readInk(scoreID: id, page: 0, draft: draft))
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try disk.writeInk(Data(repeating: 0, count: 16 * 1024 * 1024 + 1), scoreID: id, page: 0, draft: draft))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testDecodedPointBudgetRejectsCompactButComplexDrawing() throws {
        let index = index(), id = index.scores[0].id, ink = drawing(points: 250001)
        XCTAssertLessThan(ink.count, 16 * 1024 * 1024)
        try assertRejected(archive(index: index, assets: [(id, "pdf", nil, try pdf(), nil), (id, "ink", 0, ink, nil)]), limit: true)
    }
    func testValidPDFAndBothRawDrawingsRestoreWithoutRewritingBytes() throws {
        let index = index(), id = index.scores[0].id, pdf = try pdf(), ink = drawing(), draft = PKDrawing().dataRepresentation()
        let archive = try archive(index: index, assets: [(id, "pdf", nil, pdf, nil), (id, "ink", 0, ink, nil), (id, "draft", 0, draft, nil)])
        let disk = try disk(), restored = try LibraryBackup.restore(from: archive, disk: disk, current: LibraryIndex())
        let newID = try XCTUnwrap(restored.scores.first?.id)
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: newID)), pdf)
        XCTAssertEqual(try disk.readInk(scoreID: newID, page: 0), ink)
        XCTAssertEqual(try disk.readInk(scoreID: newID, page: 0, draft: true), draft)
    }
}
