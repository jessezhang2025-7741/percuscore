import XCTest
import PencilKit
import CryptoKit
@testable import Percuscore

@MainActor
final class BackupRestoreSafetyTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, LibraryDisk) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRestoreSafety-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Practice", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score] })
        return (store, disk)
    }
    private func reject(_ archive: URL, target: LibraryStore, limit: Bool = false) async throws {
        let old = target.index, disk = try XCTUnwrap(target.disk)
        let oldIndex = try Data(contentsOf: disk.root.appendingPathComponent("library.json"))
        let backup = try Data(contentsOf: archive)
        do { _ = try await target.restoreBackup(from: archive); XCTFail("Unsafe backup entered the app library") }
        catch { if limit { XCTAssertTrue(error.localizedDescription.lowercased().contains("limit")) } }
        XCTAssertEqual(target.index, old); XCTAssertEqual(try disk.load(), old)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), oldIndex)
        XCTAssertEqual(try Data(contentsOf: archive), backup)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.pdfDirectory.path).count, 1)
        XCTAssertFalse(target.isManagingLibrary)
    }
    func testAppRejectsNonPDFAndMismatchedPDFAndPreservesExportedOriginal() async throws {
        for nonPDF in [true, false] {
            let (source, disk) = try fixture(), (target, _) = try fixture()
            if nonPDF { try Data("not PDF".utf8).write(to: disk.pdfURL(for: source.index.scores[0].id)) }
            else { XCTAssertTrue(source.update { $0.scores[0].pageCount = 3 }) }
            let archive = try await source.createBackup()
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            try await reject(archive, target: target)
        }
    }
    func testAppRejectsBothBadMarkingKindsWithoutInstallingPDF() async throws {
        for draft in [false, true] {
            let (source, disk) = try fixture(), (target, _) = try fixture()
            try disk.writeInk(Data("bad drawing".utf8), scoreID: source.index.scores[0].id, page: 1, draft: draft)
            let archive = try await source.createBackup()
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            try await reject(archive, target: target)
        }
    }
    func testAppChecksForgedSizeBudgetBeforeReadingPayload() async throws {
        let (source, _) = try fixture(), (target, _) = try fixture()
        let archive = try await source.createBackup()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: archive)
        let length = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes[48..<48 + Int(length)]) as? [String: Any])
        var assets = try XCTUnwrap(header["assets"] as? [[String: Any]])
        assets[0]["count"] = UInt64(512 * 1024 * 1024 + 1); header["assets"] = assets
        let encoded = try JSONSerialization.data(withJSONObject: header)
        var changed = Data("PERCUB01".utf8), newLength = UInt64(encoded.count).bigEndian
        withUnsafeBytes(of: &newLength) { changed.append(contentsOf: $0) }
        changed.append(Data(SHA256.hash(data: encoded))); changed.append(encoded)
        changed.append(bytes.suffix(from: 48 + Int(length))); try changed.write(to: archive)
        try await reject(archive, target: target, limit: true)
    }
    func testAppRestoresValidSavedAndDraftInkWithReadingRecovery() async throws {
        let (source, disk) = try fixture(), (target, _) = try fixture()
        let id = source.index.scores[0].id, saved = PKDrawing().dataRepresentation()
        try disk.writeInk(saved, scoreID: id, page: 0)
        try disk.writeInk(saved, scoreID: id, page: 0, draft: true)
        let archive = try await source.createBackup()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let added = try await target.restoreBackup(from: archive)
        XCTAssertEqual(added, 1); XCTAssertEqual(target.index.scores.count, 2)
        let item = try XCTUnwrap(target.index.resolve(.init(scoreID: target.index.scores[1].id)))
        let model = ReaderModel(store: target, session: try XCTUnwrap(ReadingSession(queue: [item])))
        XCTAssertNotNil(model.page); XCTAssertTrue(model.recoveryAvailable)
        model.recoverDraft(); XCTAssertEqual(model.mode, .annotating)
    }
}
