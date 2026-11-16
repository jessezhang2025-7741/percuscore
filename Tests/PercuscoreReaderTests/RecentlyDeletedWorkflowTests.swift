import XCTest
import PencilKit
@testable import Percuscore

@MainActor
final class RecentlyDeletedWorkflowTests: XCTestCase {
    private func fixture() throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeletedWorkflow-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Synthetic rehearsal", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        try disk.writeInk(PKDrawing().dataRepresentation(), scoreID: score.id, page: 0, draft: true)
        var list = ScoreSetlist(title: "Concert"); list.entries = [.init(scoreID: score.id), .init(scoreID: score.id)]
        XCTAssertTrue(store.update { $0.scores = [score]; $0.setlists = [list] })
        return store
    }
    func testStoreDeleteReopenRestoreAndPermanentCleanup() async throws {
        let store = try fixture(), id = store.index.scores[0].id, disk = try XCTUnwrap(store.disk)
        XCTAssertTrue(store.moveToRecentlyDeleted(id))
        XCTAssertNil(store.score(id))
        let reopened = LibraryStore(root: disk.root)
        XCTAssertEqual(reopened.index.deletedScores.count, 1)
        XCTAssertTrue(reopened.restoreDeletedScore(id))
        XCTAssertEqual(reopened.index.setlists[0].entries.compactMap(reopened.index.resolve).count, 2)
        XCTAssertTrue(reopened.moveToRecentlyDeleted(id))
        await reopened.refreshStorage()
        XCTAssertNotNil(reopened.storageUsage?.scoreBytes[id])
        let cleaned = await reopened.deletePermanently(id)
        XCTAssertTrue(cleaned)
        XCTAssertTrue(reopened.index.scores.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.pdfURL(for: id).path))
        XCTAssertTrue(reopened.index.setlists[0].entries.isEmpty)
    }
    func testGeneratedBackupIncludesDeletedSummaryAndReopensDeleted() async throws {
        let store = try fixture(), id = store.index.scores[0].id
        XCTAssertTrue(store.moveToRecentlyDeleted(id))
        let file = try await store.createBackupFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        XCTAssertEqual(store.backupRecords.prepared?.deletedScoreCount, 1)
        XCTAssertGreaterThan(store.backupRecords.prepared?.deletedAssetBytes ?? 0, 0)
        let verified = try await store.verifyBackup(from: file.url)
        let index = try LibraryDisk(root: verified.root).load()
        XCTAssertTrue(index.activeScores.isEmpty); XCTAssertEqual(index.deletedScores.count, 1)
    }
}
