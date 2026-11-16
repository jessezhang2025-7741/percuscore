import XCTest
import PencilKit
import PDFKit
import UIKit
@testable import Percuscore

@MainActor
final class BackupWorkflowTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func fixture() throws -> LibraryStore {
        let url = try root()
        try BackupPracticeLibrary.build(at: url)
        return LibraryStore(root: url)
    }
    private func archive(_ store: LibraryStore) async throws -> URL {
        let url = try await store.createBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }
    func testStandardLibraryRoundTripReopensMulticolorInkDraftGeometryAndRepeatedReferences() async throws {
        let source = try fixture(), original = source.index
        let url = try await archive(source)
        let verified = try await source.verifyBackup(from: url)
        let reopened = LibraryStore(root: verified.root), disk = try XCTUnwrap(reopened.disk)
        XCTAssertTrue(reopened.isReady)
        XCTAssertEqual(source.index, original)
        XCTAssertEqual(reopened.index.scores.count, 2)
        let first = reopened.index.scores[0], second = reopened.index.scores[1]
        XCTAssertEqual(first.lastPage, 2)
        XCTAssertEqual(first.layouts[0]?.scale, 1.2)
        XCTAssertEqual(first.layouts[0]?.rotation, 2)
        XCTAssertEqual(first.viewports[0]?.scale, 1.75)
        XCTAssertEqual(first.bookmarks.map(\.startPage), [0, 1])
        XCTAssertEqual(first.bookmarks.map(\.endPage), [nil, 3])
        let ink = try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: first.id, page: 0)))
        let draft = try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: first.id, page: 0, draft: true)))
        XCTAssertEqual(ink.strokes.count, 2); XCTAssertEqual(draft.strokes.count, 3)
        XCTAssertTrue(ink.strokes[0].ink.color.isEqual(UIColor.red))
        XCTAssertTrue(ink.strokes[1].ink.color.isEqual(UIColor.blue))
        XCTAssertEqual(reopened.index.setlists[0].entries.map(\.scoreID), [first.id, second.id, first.id, second.id, first.id])
        XCTAssertEqual(reopened.index.resolve(reopened.index.setlists[0].entries[2])?.startPage, 1)
        XCTAssertEqual(reopened.index.resolve(reopened.index.setlists[0].entries[4])?.endPage, 3)
        XCTAssertNotEqual(first.id, original.scores[0].id)
        XCTAssertEqual(verified.evidence.verification.savedInkCount, 3)
        XCTAssertEqual(verified.evidence.verification.draftCount, 1)
        let model = ReaderModel(store: reopened, session: try XCTUnwrap(ReadingSession(queue: [reopened.index.resolve(.init(scoreID: first.id))!])))
        XCTAssertTrue(model.recoveryAvailable); model.recoverDraft()
        XCTAssertEqual(model.canvas.drawing.strokes.count, 3)
        XCTAssertEqual(model.mode, .annotating)
    }
    func testRestoreIntoNonemptyLibraryKeepsExistingFilesAndSettings() async throws {
        let source = try fixture(), target = try fixture(), old = target.index, disk = try XCTUnwrap(target.disk)
        let bytes = try Data(contentsOf: disk.pdfURL(for: old.scores[0].id))
        XCTAssertTrue(target.update { $0.settings.halfPageTurns = false })
        let url = try await archive(source)
        let count = try await target.restoreBackup(from: url)
        XCTAssertEqual(count, 2)
        let reopened = LibraryStore(root: disk.root)
        XCTAssertEqual(Array(reopened.index.scores.prefix(2)), old.scores)
        XCTAssertEqual(reopened.index.setlists[0], old.setlists[0])
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: old.scores[0].id)), bytes)
        XCTAssertFalse(reopened.index.settings.halfPageTurns)
        XCTAssertEqual(reopened.index.scores.count, 4)
        XCTAssertEqual(reopened.index.setlists.count, 2)
    }
    func testGeneratedCancelledExportedAndVerifiedAreIndependentFileBoundStates() async throws {
        let store = try fixture(), url = try await archive(store)
        let sha = try LibraryBackup.fileSHA256(url)
        XCTAssertEqual(store.backupRecords.prepared?.sha256, sha)
        XCTAssertNil(store.backupRecords.exported); XCTAssertNil(store.backupRecords.verification)
        try store.completeBackupExport(saved: false, archiveSHA256: sha)
        XCTAssertNil(store.backupRecords.exported)
        try store.completeBackupExport(saved: true, archiveSHA256: sha)
        XCTAssertEqual(store.backupRecords.exported?.sha256, sha)
        XCTAssertNil(store.backupRecords.verification)
        let verified = try await store.verifyBackup(from: url)
        XCTAssertNotNil(verified.evidence.exportedAt)
        XCTAssertEqual(verified.evidence.physicalFilesStatus, .incomplete)
        let reopened = LibraryStore(root: store.disk!.root)
        XCTAssertEqual(reopened.backupRecords.verification?.verification.archiveSHA256, sha)
        XCTAssertEqual(reopened.backupRecords.exported?.sha256, sha)
    }
    func testVerifyingAnotherFileCannotInheritPreviousExportEvidence() async throws {
        let store = try fixture(), first = try await archive(store)
        try store.completeBackupExport(saved: true, archiveSHA256: LibraryBackup.fileSHA256(first))
        XCTAssertTrue(store.update { $0.scores[0].title = "Later version" })
        let other = try await archive(store), verified = try await store.verifyBackup(from: other)
        XCTAssertNil(verified.evidence.exportedAt)
        XCTAssertNotNil(verified.evidence.preparedAt)
        XCTAssertEqual(verified.evidence.physicalFilesStatus, .incomplete)
    }
    func testReaderDraftWriteFailsSafelyDuringSnapshotAndCanRetryAfterward() throws {
        let store = try fixture(), disk = try XCTUnwrap(store.disk), score = store.index.scores[1]
        let model = ReaderModel(store: store, session: try XCTUnwrap(ReadingSession(queue: [store.index.resolve(.init(scoreID: score.id))!])))
        model.beginAnnotation()
        let lease = disk.beginBackupSnapshot()
        model.flushDraft()
        XCTAssertEqual(model.saveState, .failed)
        XCTAssertNil(try disk.readInk(scoreID: score.id, page: 0, draft: true))
        lease.release(); model.flushDraft()
        XCTAssertNotNil(try disk.readInk(scoreID: score.id, page: 0, draft: true))
    }
    func testEvidenceWriteFailureDoesNotLoseGeneratedFileOrClaimPersistentExport() async throws {
        let store = try fixture(), disk = try XCTUnwrap(store.disk)
        try FileManager.default.createDirectory(at: disk.root.appendingPathComponent("backup-records.json"), withIntermediateDirectories: false)
        let url = try await archive(store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(store.backupEvidenceError)
        XCTAssertNotNil(store.backupRecords.prepared)
        XCTAssertThrowsError(try store.completeBackupExport(saved: true, archiveSHA256: LibraryBackup.fileSHA256(url)))
        XCTAssertNil(store.backupRecords.exported)
        let verified = try await store.verifyBackup(from: url)
        XCTAssertEqual(verified.evidence.physicalFilesStatus, .incomplete)
        XCTAssertNotNil(store.backupEvidenceError)
        let reopened = LibraryStore(root: disk.root)
        XCTAssertTrue(reopened.isReady)
        XCTAssertNil(reopened.backupRecords.verification)
        XCTAssertNotNil(reopened.backupEvidenceError)
    }
    func testReportExportAndRemovingCopiesPreserveLibraryArchiveAndEvidence() async throws {
        let store = try fixture(), index = store.index, url = try await archive(store)
        let bytes = try Data(contentsOf: url), verified = try await store.verifyBackup(from: url)
        let report = try BackupVerificationService.exportReport(verified.evidence)
        defer { try? FileManager.default.removeItem(at: report[0].deletingLastPathComponent()) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupVerificationEvidence.self, from: Data(contentsOf: report[1]))
        XCTAssertEqual(decoded.verification.archiveSHA256, try LibraryBackup.fileSHA256(url))
        XCTAssertEqual(decoded.physicalFilesStatus, .incomplete)
        XCTAssertTrue(try String(contentsOf: report[0]).contains("operator observations"))
        XCTAssertNotNil(store.verifiedBackupRoot)
        try store.removeVerificationCopies()
        XCTAssertNil(store.verifiedBackupRoot)
        XCTAssertEqual(store.index, index)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(LibraryStore(root: store.disk!.root).backupRecords.verification?.id, verified.evidence.id)
    }

}
