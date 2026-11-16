import XCTest
@testable import PercuscoreCore

final class InkCommitTests: XCTestCase {
    private func disk() throws -> LibraryDisk {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InkCommit-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LibraryDisk(root: root)
    }
    func testPreparedIntentDoesNotRetireDraftUntilItsDrawingIsCommitted() throws {
        let disk = try disk(), id = UUID()
        try disk.writeInk(Data([1]), scoreID: id, page: 0)
        try disk.writeInk(Data([2]), scoreID: id, page: 0, draft: true)
        try disk.prepareInkCommit(Data([3]), scoreID: id, page: 0)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: disk.inkDirectory.path) }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: disk.inkDirectory.path)
        XCTAssertThrowsError(try disk.writeInk(Data([3]), scoreID: id, page: 0), "Fail the real replacement after intent is durable")
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.readInk(scoreID: id, page: 0), Data([1]))
        XCTAssertEqual(try reopened.readInk(scoreID: id, page: 0, draft: true), Data([2]))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: disk.inkDirectory.path)
        try reopened.writeInk(Data([3]), scoreID: id, page: 0)
        XCTAssertNil(try reopened.readInk(scoreID: id, page: 0, draft: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.inkURL(id, page: 0, draft: true).path))
        XCTAssertTrue(try reopened.cleanupCommittedDraft(scoreID: id, page: 0))
        XCTAssertEqual(try reopened.readInk(scoreID: id, page: 0), Data([3]))
    }
    func testPreviousRetirementSurvivesInterruptionBeforeNextCommit() throws {
        let disk = try disk(), id = UUID()
        try disk.writeInk(Data([1]), scoreID: id, page: 0, draft: true)
        try disk.commitInk(Data([2]), scoreID: id, page: 0)
        XCTAssertNil(try disk.readInk(scoreID: id, page: 0, draft: true))
        try disk.prepareInkCommit(Data([3]), scoreID: id, page: 0)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: disk.inkDirectory.path) }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: disk.inkDirectory.path)
        XCTAssertThrowsError(try disk.writeInk(Data([3]), scoreID: id, page: 0))
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.readInk(scoreID: id, page: 0), Data([2]))
        XCTAssertNil(try reopened.readInk(scoreID: id, page: 0, draft: true),
                     "A later, unfinished commit cannot undo a previous retirement")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: disk.inkDirectory.path)
        try reopened.writeInk(Data([3]), scoreID: id, page: 0)
        XCTAssertNil(try reopened.readInk(scoreID: id, page: 0, draft: true))
    }
    func testSameBytesInNewDraftGenerationAreNotRetiredByOldCommit() throws {
        let disk = try disk(), id = UUID()
        try disk.writeInk(Data([1]), scoreID: id, page: 0, draft: true)
        try disk.commitInk(Data([2]), scoreID: id, page: 0)
        try disk.writeInk(Data([1]), scoreID: id, page: 0, draft: true)
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 0, draft: true), Data([1]))
        XCTAssertFalse(try disk.cleanupCommittedDraft(scoreID: id, page: 0))
        try disk.prepareInkCommit(Data([3]), scoreID: id, page: 0)
        XCTAssertEqual(try LibraryDisk(root: disk.root).readInk(scoreID: id, page: 0, draft: true), Data([1]))
        try disk.writeInk(Data([3]), scoreID: id, page: 0)
        XCTAssertNil(try disk.readInk(scoreID: id, page: 0, draft: true))
    }
    func testRawLegacyDraftCanBeRecoveredAndRetired() throws {
        let disk = try disk(), id = UUID(), legacy = Data([8, 9, 10])
        try legacy.write(to: disk.inkURL(id, page: 0, draft: true))
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 0, draft: true), legacy)
        try disk.commitInk(Data([1]), scoreID: id, page: 0)
        XCTAssertNil(try LibraryDisk(root: disk.root).readInk(scoreID: id, page: 0, draft: true))
        try disk.writeInk(legacy, scoreID: id, page: 0, draft: true)
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 0, draft: true), legacy)
    }
    func testPortableBackupKeepsGenuineDraftAssetInRawFormat() throws {
        let disk = try disk(), score = Score(title: "Raw draft backup", pageCount: 1)
        var index = LibraryIndex(); index.scores = [score]; try disk.save(index)
        try BackupTestAssets.writePDF(to: disk.pdfURL(for: score.id), pages: 1)
        try disk.writeInk(BackupTestAssets.savedInk, scoreID: score.id, page: 0)
        let draft = BackupTestAssets.draftInk
        try disk.writeInk(draft, scoreID: score.id, page: 0, draft: true)
        let archive = disk.root.appendingPathComponent("raw.percuscorebackup")
        try LibraryBackup.export(index: index, disk: disk, to: archive)
        let target = try self.disk()
        let restored = try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex())
        let id = try XCTUnwrap(restored.scores.first?.id)
        XCTAssertEqual(try Data(contentsOf: target.inkURL(id, page: 0, draft: true)), draft,
                       "The portable asset remains directly readable by older raw-draft readers")
        XCTAssertEqual(try target.readInk(scoreID: id, page: 0), BackupTestAssets.savedInk)
        XCTAssertEqual(try target.readInk(scoreID: id, page: 0, draft: true), draft)
    }
}
