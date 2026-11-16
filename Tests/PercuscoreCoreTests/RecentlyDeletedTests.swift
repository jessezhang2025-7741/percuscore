import XCTest
@testable import PercuscoreCore

final class RecentlyDeletedTests: XCTestCase {
    private func fixture() throws -> (LibraryDisk, LibraryIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeletedTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var index = LibraryIndex(), score = Score(title: "Rehearsal", pageCount: 3)
        score.bookmarks = [.init(title: "Excerpt", startPage: 1, endPage: 2)]
        score.layouts[1] = PageLayout(); score.viewports[2] = PageViewport(); score.lastPage = 2
        index.scores = [score]
        var list = ScoreSetlist(title: "Program")
        list.entries = [.init(scoreID: score.id), .init(scoreID: score.id, bookmarkID: score.bookmarks[0].id), .init(scoreID: score.id)]
        index.setlists = [list]
        try Data([1, 2, 3]).write(to: disk.pdfURL(for: score.id))
        try disk.writeInk(Data([4, 5]), scoreID: score.id, page: 1)
        try disk.writeInk(Data([6]), scoreID: score.id, page: 2, draft: true)
        try disk.save(index)
        return (disk, index)
    }
    func testDeleteReopenRestoreKeepsAllMetadataAndOriginalReferences() throws {
        let (disk, original) = try fixture(), id = original.scores[0].id
        var deleted = original; deleted.removeScore(id)
        XCTAssertTrue(deleted.activeScores.isEmpty)
        XCTAssertEqual(deleted.deletedScores.count, 1)
        XCTAssertEqual(deleted.setlists, original.setlists)
        XCTAssertNil(deleted.resolve(original.setlists[0].entries[0]))
        let timestamp = deleted.scores[0].deletedAt
        deleted.removeScore(id)
        XCTAssertEqual(deleted.scores[0].deletedAt, timestamp)
        try disk.save(deleted)
        var reopened = try LibraryDisk(root: disk.root).load()
        XCTAssertEqual(reopened, deleted)
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 1), Data([4, 5]))
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 2, draft: true), Data([6]))
        reopened.restoreScore(id)
        XCTAssertEqual(reopened, original)
        XCTAssertEqual(reopened.setlists[0].entries.compactMap(reopened.resolve).count, 3)
        try disk.save(reopened)
        XCTAssertEqual(try disk.load(), original)
    }
    func testVersionOneMigratesAndFutureVersionIsRejected() throws {
        let (disk, index) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as? [String: Any])
        object["version"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: disk.root.appendingPathComponent("library.json"))
        let loaded = try disk.load()
        XCTAssertEqual(loaded.version, 2); XCTAssertEqual(loaded.activeScores.count, 1)
        try disk.save(loaded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: disk.root.appendingPathComponent("library.json"))) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
    }
    func testInterruptedPurgeIsVisibleAndRetryCompletesWithoutTouchingOrphans() throws {
        let (disk, original) = try fixture(), id = original.scores[0].id
        let orphan = disk.pdfURL(for: UUID()); try Data([9, 9]).write(to: orphan)
        var index = original; index.removeScore(id); try disk.save(index)
        XCTAssertThrowsError(try disk.permanentlyDelete(id, checkpoint: { stage in
            if case .removedAsset = stage { throw CocoaError(.fileWriteUnknown) }
        }))
        let reopenedDisk = try LibraryDisk(root: disk.root)
        var pending = try reopenedDisk.load()
        XCTAssertNotNil(pending.scores.first?.purgePendingAt)
        pending.restoreScore(id)
        XCTAssertTrue(pending.activeScores.isEmpty)
        XCTAssertThrowsError(try reopenedDisk.writeInk(Data([7]), scoreID: id, page: 1))
        XCTAssertThrowsError(try reopenedDisk.save(original), "A stale window must not resurrect a purging score")
        let finished = try reopenedDisk.permanentlyDelete(id)
        XCTAssertTrue(finished.scores.isEmpty); XCTAssertTrue(finished.setlists[0].entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: orphan), Data([9, 9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.pdfURL(for: id).path))
        XCTAssertNil(try disk.readInk(scoreID: id, page: 1))
        XCTAssertNil(try disk.readInk(scoreID: id, page: 2, draft: true))
        XCTAssertEqual(try disk.permanentlyDelete(id), finished, "Repeated cleanup is idempotent")
        XCTAssertThrowsError(try disk.writeInk(Data([8]), scoreID: id, page: 0, draft: true))
    }
    func testPurgeIntentAndCompletedTombstoneOverrideOldIndexFallback() throws {
        for stageToFail in [0, 1] {
            let (disk, original) = try fixture(), id = original.scores[0].id
            var index = original; index.removeScore(id); try disk.save(index)
            if stageToFail == 0 {
                XCTAssertThrowsError(try disk.permanentlyDelete(id, checkpoint: { stage in
                    if case .intentRecorded = stage { throw CocoaError(.fileWriteUnknown) }
                }))
            } else { _ = try disk.permanentlyDelete(id) }
            try JSONEncoder().encode(original).write(to: disk.root.appendingPathComponent("library.backup.json"))
            try Data("damaged".utf8).write(to: disk.root.appendingPathComponent("library.json"))
            let loaded = try LibraryDisk(root: disk.root).load()
            XCTAssertTrue(loaded.activeScores.isEmpty)
            if stageToFail == 0 {
                XCTAssertNotNil(loaded.scores[0].purgePendingAt)
                XCTAssertEqual(loaded.setlists[0].entries.count, 3)
            } else { XCTAssertTrue(loaded.scores.isEmpty); XCTAssertTrue(loaded.setlists[0].entries.isEmpty) }
        }
    }
    func testStorageCountsReferencesOnceAndCacheNeverCleansUserFiles() throws {
        let (disk, original) = try fixture(), id = original.scores[0].id
        let orphan = disk.inkDirectory.appendingPathComponent("old-unindexed.drawing")
        try Data([1, 2, 3, 4]).write(to: orphan)
        try FileManager.default.createDirectory(at: disk.cacheDirectory, withIntermediateDirectories: true)
        try Data([8, 8]).write(to: disk.cacheDirectory.appendingPathComponent("thumbnail"))
        var index = original; index.removeScore(id); try disk.save(index)
        let report = try disk.storageUsage(index: index)
        XCTAssertEqual(report.pdfBytes, 3); XCTAssertEqual(report.savedInkBytes, 2)
        XCTAssertGreaterThan(report.draftBytes, 0)
        XCTAssertEqual(report.recentlyDeletedBytes, report.pdfBytes + report.savedInkBytes + report.draftBytes)
        XCTAssertEqual(report.retainedFiles.count, 1); XCTAssertEqual(report.retainedBytes, 4)
        XCTAssertEqual(report.cacheBytes, 2)
        XCTAssertEqual(report.scoreBytes[id], report.recentlyDeletedBytes)
        try disk.clearCache()
        XCTAssertEqual(try disk.storageUsage(index: index).cacheBytes, 0)
        XCTAssertEqual(try Data(contentsOf: orphan), Data([1, 2, 3, 4]))
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 2, draft: true), Data([6]))
    }
    func testActiveScoreCannotBePermanentlyDeleted() throws {
        let (disk, index) = try fixture()
        XCTAssertThrowsError(try disk.permanentlyDelete(index.scores[0].id))
        XCTAssertEqual(try disk.load(), index)
    }
    func testFailureAfterLastFileOrIndexCommitRemainsRetryable() throws {
        for afterIndex in [false, true] {
            let (disk, original) = try fixture(), id = original.scores[0].id
            var index = original; index.removeScore(id); try disk.save(index)
            XCTAssertThrowsError(try disk.permanentlyDelete(id, checkpoint: { stage in
                switch stage {
                case .beforeIndexCommit where !afterIndex: throw CocoaError(.fileWriteUnknown)
                case .indexCommitted where afterIndex: throw CocoaError(.fileWriteUnknown)
                default: break
                }
            }))
            let loaded = try LibraryDisk(root: disk.root).load()
            XCTAssertEqual(loaded.deletedScores.count, 1)
            XCTAssertNotNil(loaded.deletedScores.first?.purgePendingAt)
            XCTAssertTrue(try disk.permanentlyDelete(id).scores.isEmpty)
        }
    }
    func testIndexWriteFailureAfterCleanupStillShowsPendingRetry() throws {
        let (disk, original) = try fixture(), id = original.scores[0].id
        var index = original; index.removeScore(id); try disk.save(index)
        XCTAssertThrowsError(try disk.permanentlyDelete(id, checkpoint: { stage in
            if case .beforeIndexCommit = stage {
                let backup = disk.root.appendingPathComponent("library.backup.json")
                try FileManager.default.removeItem(at: backup)
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            }
        }))
        let loaded = try disk.load()
        XCTAssertNotNil(loaded.deletedScores.first?.purgePendingAt)
        try FileManager.default.removeItem(at: disk.root.appendingPathComponent("library.backup.json"))
        XCTAssertTrue(try disk.permanentlyDelete(id).scores.isEmpty)
    }
    func testRedirectedCacheAndAssetDirectoryNeverDeleteTheirTargets() throws {
        let (disk, original) = try fixture(), id = original.scores[0].id
        let outside = disk.root.appendingPathComponent("separate"), fm = FileManager.default
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let keep = outside.appendingPathComponent("keep"); try Data([9]).write(to: keep)
        try fm.createSymbolicLink(at: disk.cacheDirectory, withDestinationURL: outside)
        XCTAssertThrowsError(try disk.clearCache())
        XCTAssertEqual(try Data(contentsOf: keep), Data([9]))
        try fm.removeItem(at: disk.cacheDirectory)
        var index = original; index.removeScore(id); try disk.save(index)
        try fm.moveItem(at: disk.inkDirectory, to: disk.root.appendingPathComponent("preserved-ink"))
        try fm.createSymbolicLink(at: disk.inkDirectory, withDestinationURL: outside)
        XCTAssertThrowsError(try disk.permanentlyDelete(id))
        XCTAssertEqual(try Data(contentsOf: keep), Data([9]))
        XCTAssertTrue(fm.fileExists(atPath: disk.pdfURL(for: id).path))
    }
    func testUnknownFilenameBelongingToDeletedScoreIsRetained() throws {
        let (disk, original) = try fixture(), id = original.scores[0].id
        let unknown = disk.inkDirectory.appendingPathComponent("\(id.uuidString)-unknown.drawing")
        try Data([7]).write(to: unknown)
        var index = original; index.removeScore(id); try disk.save(index)
        XCTAssertEqual(try disk.storageUsage(index: index).retainedFiles.count, 1)
        _ = try disk.permanentlyDelete(id)
        XCTAssertEqual(try Data(contentsOf: unknown), Data([7]))
    }
}
