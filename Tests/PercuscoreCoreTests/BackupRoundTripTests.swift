import XCTest
import CryptoKit
@testable import PercuscoreCore

final class BackupRoundTripTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ disk: LibraryDisk) throws -> LibraryIndex {
        try BackupTests().fixture(disk)
    }
    private func asset(_ id: UUID, _ bytes: Data) -> RestoreTransaction.Asset {
        .init(scoreID: id, page: nil, kind: "pdf", count: UInt64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
    }
    func testSnapshotBlocksWritesThroughBothDiskInstancesUntilReleased() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let other = try LibraryDisk(root: disk.root)
        let id = original.scores[0].id
        let lease = disk.beginBackupSnapshot()
        let nested = other.beginBackupSnapshot()
        XCTAssertThrowsError(try other.save(LibraryIndex()))
        XCTAssertThrowsError(try disk.writeInk(Data(), scoreID: id, page: 2))
        XCTAssertThrowsError(try other.commitInk(Data(), scoreID: id, page: 2))
        XCTAssertThrowsError(try disk.discardDraft(scoreID: id, page: 2))
        XCTAssertThrowsError(try other.cleanupCommittedDraft(scoreID: id, page: 2))
        lease.release(); lease.release()
        XCTAssertThrowsError(try other.writeInk(Data(), scoreID: id, page: 2))
        nested.release()
        XCTAssertEqual(try disk.load(), original)
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 2), BackupTestAssets.savedInk)
        try other.writeInk(BackupTestAssets.savedInk, scoreID: id, page: 2)
    }
    func testFailedExportReleasesItsWriteBarrier() throws {
        let disk = try LibraryDisk(root: folder())
        var missing = LibraryIndex(); missing.scores = [Score(title: "Missing", pageCount: 1)]
        XCTAssertThrowsError(try LibraryBackup.export(index: missing, disk: disk, to: disk.root.appendingPathComponent("bad.percuscorebackup")))
        try disk.save(LibraryIndex())
        XCTAssertTrue(try disk.load().scores.isEmpty)
    }
    func testVerificationRestoresReopensAndComparesContentDespiteNewIDs() throws {
        let source = try LibraryDisk(root: folder()), original = try fixture(source)
        let archive = try folder().appendingPathComponent("roundtrip.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let originalBytes = try Data(contentsOf: archive)
        let destination = try folder().appendingPathComponent("isolated")
        let result = try LibraryBackup.verify(from: archive, at: destination)
        XCTAssertEqual(result.scoreCount, 1); XCTAssertEqual(result.setlistCount, 1)
        XCTAssertEqual(result.pdfCount, 1); XCTAssertEqual(result.savedInkCount, 1); XCTAssertEqual(result.draftCount, 1)
        XCTAssertEqual(result.archiveSHA256, Data(SHA256.hash(data: originalBytes)).map { String(format: "%02x", $0) }.joined())
        let restoredDisk = try LibraryDisk(root: destination), reopened = try restoredDisk.load()
        XCTAssertNotEqual(reopened.scores[0].id, original.scores[0].id)
        XCTAssertNotEqual(reopened.setlists[0].id, original.setlists[0].id)
        XCTAssertNotEqual(reopened.setlists[0].entries[0].id, original.setlists[0].entries[0].id)
        XCTAssertEqual(try BackupContentSnapshot.capture(index: original, disk: source),
                       try BackupContentSnapshot.capture(index: reopened, disk: restoredDisk))
        XCTAssertEqual(try Data(contentsOf: archive), originalBytes)
    }
    func testContentComparisonDetectsMissingDraftChangedCropAndWrongReferences() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let before = try BackupContentSnapshot.capture(index: original, disk: disk)
        try disk.discardDraft(scoreID: original.scores[0].id, page: 2)
        XCTAssertNotEqual(try BackupContentSnapshot.capture(index: original, disk: disk), before)
        try disk.writeInk(BackupTestAssets.draftInk, scoreID: original.scores[0].id, page: 2, draft: true)
        var crop = original; crop.scores[0].layouts[2]?.scale = 1.75
        XCTAssertNotEqual(try BackupContentSnapshot.capture(index: crop, disk: disk), before)
        var reference = original; reference.setlists[0].entries[1].bookmarkID = nil
        XCTAssertNotEqual(try BackupContentSnapshot.capture(index: reference, disk: disk), before)
    }
    func testVerificationNeverUsesAnExistingDestination() throws {
        let source = try LibraryDisk(root: folder()), original = try fixture(source)
        let archive = try folder().appendingPathComponent("copy.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        XCTAssertThrowsError(try LibraryBackup.verify(from: archive, at: source.root))
        XCTAssertEqual(try source.load(), original)
    }
    func testLoadRollsBackPartialInstallAndKeepsOriginalLibrary() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let newID = UUID()
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        let bytes = Data("partially installed".utf8)
        let transaction = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [newID], assets: [asset(newID, bytes)])
        try bytes.write(to: disk.pdfURL(for: newID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.journalURL.path))
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.pdfURL(for: newID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try reopened.readInk(scoreID: original.scores[0].id, page: 2), BackupTestAssets.savedInk)
    }
    func testLoadPreservesCommittedRestoreAndOnlyCleansItsStage() throws {
        let disk = try LibraryDisk(root: folder())
        let newID = UUID(), stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        try BackupTestAssets.writePDF(to: disk.pdfURL(for: newID), pages: 1)
        _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [newID], assets: [asset(newID, try Data(contentsOf: disk.pdfURL(for: newID)))])
        var committed = LibraryIndex(); committed.scores = [Score(id: newID, title: "Committed", pageCount: 1)]
        try disk.save(committed)
        XCTAssertEqual(try LibraryDisk(root: disk.root).load(), committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: newID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testCorruptJournalCannotBlockOriginalLibraryOrDeleteUnknownFiles() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("damaged journal".utf8).write(to: stage.appendingPathComponent("transaction.json"))
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: original.scores[0].id).path))
    }
    func testRecoveryFromBackupIndexNeverDeletesUncertainRestoreAssets() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        try disk.save(original)
        let newID = UUID(), stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        let bytes = Data("possibly committed asset".utf8)
        _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [newID], assets: [asset(newID, bytes)])
        try bytes.write(to: disk.pdfURL(for: newID))
        try Data("damaged primary".utf8).write(to: disk.root.appendingPathComponent("library.json"))
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertTrue(reopened.recoveredFromBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: newID).path))
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
    }
    func testStagingInterruptionRemovesOnlyOwnedStageAndPreservesUnmarkedWorkspace() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let owned = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        try RestoreTransaction.beginStaging(at: owned, disk: disk)
        let unknown = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
    }
    func testMismatchedAssetPreservesEntireRecoverySetUntilSafeRetry() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let first = UUID(), second = UUID(), expected = Data("owned".utf8), changed = Data("changed".utf8)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [first, second], assets: [asset(first, expected), asset(second, expected)])
        try expected.write(to: disk.pdfURL(for: first)); try changed.write(to: disk.pdfURL(for: second))
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: first)), expected)
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: second)), changed)
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
        try expected.write(to: disk.pdfURL(for: second))
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertNil(reopened.restoreRecoveryWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testPartialIndexCommitPreservesAllAssetsAndWarns() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let first = UUID(), second = UUID(), bytes = Data("owned".utf8)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [first, second], assets: [asset(first, bytes), asset(second, bytes)])
        try bytes.write(to: disk.pdfURL(for: first)); try bytes.write(to: disk.pdfURL(for: second))
        var partial = original; partial.scores.append(Score(id: first, title: "Partial", pageCount: 1)); try disk.save(partial)
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: second).path))
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
    }
    func testCleanupWriteFailureKeepsIntentAndCanRetryNextLoad() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let id = UUID(), bytes = Data("owned".utf8)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [id], assets: [asset(id, bytes)])
        try bytes.write(to: disk.pdfURL(for: id))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: disk.pdfDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: disk.pdfDirectory.path) }
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: disk.pdfDirectory.path)
        XCTAssertEqual(try reopened.load(), original)
        XCTAssertNil(reopened.restoreRecoveryWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.pdfURL(for: id).path))
    }
    func testUnsupportedVersionAndPayloadTruncationPreserveExistingLibraryAndArchive() throws {
        let source = try LibraryDisk(root: folder()), index = try fixture(source)
        let archive = try folder().appendingPathComponent("bad.percuscorebackup")
        try LibraryBackup.export(index: index, disk: source, to: archive)
        let valid = try Data(contentsOf: archive)
        let target = try LibraryDisk(root: folder()), current = try fixture(target)
        let before = try BackupContentSnapshot.capture(index: current, disk: target)
        var header = valid.subdata(in: 16..<48)
        let length = valid[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.subdata(in: 48..<(48 + Int(length)))) as? [String: Any])
        object["version"] = 999
        let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var unsupported = Data("PERCUB01".utf8)
        var size = UInt64(manifest.count).bigEndian; withUnsafeBytes(of: &size) { unsupported.append(contentsOf: $0) }
        header = Data(SHA256.hash(data: manifest)); unsupported.append(header); unsupported.append(manifest)
        unsupported.append(valid.dropFirst(48 + Int(length)))
        for bytes in [Data(valid.dropLast(20)), unsupported] {
            try bytes.write(to: archive)
            XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: target, current: current))
            XCTAssertEqual(try target.load(), current)
            XCTAssertEqual(try BackupContentSnapshot.capture(index: current, disk: target), before)
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
        }
    }
    func testTransactionRejectsDuplicateDestinations() throws {
        let disk = try LibraryDisk(root: folder()), id = UUID(), bytes = Data("owned".utf8)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        XCTAssertThrowsError(try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [id], assets: [asset(id, bytes), asset(id, bytes)]))
    }

    func testLoadWaitsForActiveRestoreBeforeCleaningItsStage() throws {
        let disk = try LibraryDisk(root: folder()), original = try fixture(disk)
        let other = try LibraryDisk(root: disk.root), id = UUID(), bytes = Data("installed".utf8)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        let started = DispatchSemaphore(value: 0), loaded = DispatchSemaphore(value: 0)
        try disk.withExclusiveWrite {
            _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [id], assets: [asset(id, bytes)])
            try bytes.write(to: disk.pdfURL(for: id))
            DispatchQueue.global().async { started.signal(); _ = try? other.load(); loaded.signal() }
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(loaded.wait(timeout: .now() + 0.1), .timedOut)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
            var committed = original; committed.scores.append(Score(id: id, title: "Committed", pageCount: 1))
            try disk.save(committed)
        }
        XCTAssertEqual(loaded.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try disk.load().scores.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: id).path))
    }
    func testRecoveryRejectsRedirectedAssetDirectoryEvenInsideRoot() throws {
        let disk = try LibraryDisk(root: folder()), id = UUID(), bytes = Data("owned".utf8)
        let stage = disk.root.appendingPathComponent(".restore-\(UUID().uuidString)")
        _ = try RestoreTransaction.prepare(at: stage, disk: disk, scoreIDs: [id], assets: [asset(id, bytes)])
        let kept = disk.root.appendingPathComponent("Kept")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let preserved = kept.appendingPathComponent(id.uuidString + ".pdf")
        try bytes.write(to: preserved)
        try FileManager.default.removeItem(at: disk.pdfDirectory)
        try FileManager.default.createSymbolicLink(at: disk.pdfDirectory, withDestinationURL: kept)
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertTrue(try reopened.load().scores.isEmpty)
        XCTAssertNotNil(reopened.restoreRecoveryWarning)
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
    }

    func testVerificationAcceptsNestedDirectoryWithoutDirectoryURLHint() throws {
        let disk = try LibraryDisk(root: folder()), index = try fixture(disk)
        let archive = try folder().appendingPathComponent("nested.percuscorebackup")
        try LibraryBackup.export(index: index, disk: disk, to: archive)
        let destination = try folder().appendingPathComponent("one/two/restored", isDirectory: false)
        let result = try LibraryBackup.verify(from: archive, at: destination)
        XCTAssertEqual(result.scoreCount, 1)
        XCTAssertEqual(try LibraryDisk(root: destination).load().scores.count, 1)
    }

}
