import XCTest
@testable import PercuscoreCore

final class BackupTests: XCTestCase {
    func testDeletedBackupRoundTripPreservesStateAssetsAndRepeatedPositions() throws {
        let source = try LibraryDisk(root: folder())
        var original = try fixture(source); original.removeScore(original.scores[0].id); try source.save(original)
        let archive = try folder().appendingPathComponent("deleted.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let summary = try LibraryBackup.deletedSummary(from: archive)
        XCTAssertEqual(summary.count, 1); XCTAssertGreaterThan(summary.bytes, 0)
        let target = try LibraryDisk(root: folder())
        var restored = try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex())
        XCTAssertTrue(restored.activeScores.isEmpty)
        XCTAssertEqual(restored.scores[0].deletedAt, original.scores[0].deletedAt)
        XCTAssertEqual(restored.setlists[0].entries.count, 2)
        XCTAssertEqual(try target.readInk(scoreID: restored.scores[0].id, page: 2, draft: true), BackupTestAssets.draftInk)
        restored.restoreScore(restored.scores[0].id)
        XCTAssertEqual(restored.setlists[0].entries.compactMap(restored.resolve).count, 2)
        let evidence = try LibraryBackup.verify(from: archive, at: folder().appendingPathComponent("verified"))
        XCTAssertEqual(evidence.deletedScoreCount, 1); XCTAssertEqual(evidence.deletedAssetBytes, summary.bytes)
    }
    func testPendingPurgeCannotBeExportedAsAnIncompleteBackup() throws {
        let source = try LibraryDisk(root: folder())
        var original = try fixture(source); original.removeScore(original.scores[0].id); try source.save(original)
        XCTAssertThrowsError(try source.permanentlyDelete(original.scores[0].id, checkpoint: { _ in throw CocoaError(.fileWriteUnknown) }))
        let archive = try folder().appendingPathComponent("pending.percuscorebackup")
        XCTAssertThrowsError(try LibraryBackup.export(index: original, disk: source, to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func fixture(_ disk: LibraryDisk) throws -> LibraryIndex {
        var library = LibraryIndex()
        var score = Score(title: "Mahler", pageCount: 4)
        score.composer = "Mahler"; score.part = "Timpani"; score.tags = ["Concert"]
        score.bookmarks = [.init(title: "Finale", startPage: 2, endPage: 3)]
        var layout = PageLayout(); layout.scale = 1.5; layout.divider = 0.4
        score.layouts[2] = layout; score.lastPage = 2; score.isFavorite = true
        var viewport = PageViewport(); viewport.scale = 2.5; viewport.offsetX = 0.2; viewport.offsetY = -0.3
        score.viewports[2] = viewport
        library.scores = [score]
        var list = ScoreSetlist(title: "Concert")
        list.entries = [.init(scoreID: score.id), .init(scoreID: score.id, bookmarkID: score.bookmarks[0].id)]
        library.setlists = [list]; library.settings.halfPageTurns = true
        try BackupTestAssets.writePDF(to: disk.pdfURL(for: score.id), pages: 4)
        try disk.writeInk(BackupTestAssets.savedInk, scoreID: score.id, page: 2)
        try disk.writeInk(BackupTestAssets.draftInk, scoreID: score.id, page: 2, draft: true)
        try disk.save(library)
        return library
    }
    func testPortableRoundTripAndMergeKeepAllReferences() throws {
        let source = try LibraryDisk(root: folder())
        let original = try fixture(source)
        let archive = try folder().appendingPathComponent("test.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let target = try LibraryDisk(root: folder())
        let first = try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex())
        XCTAssertEqual(first.scores.count, 1)
        let restored = first.scores[0]
        var expected = original.scores[0]; expected.id = restored.id
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(first.settings, original.settings)
        XCTAssertEqual(first.resolve(first.setlists[0].entries[1])?.startPage, 2)
        XCTAssertEqual(try target.readInk(scoreID: restored.id, page: 2), BackupTestAssets.savedInk)
        XCTAssertEqual(try target.readInk(scoreID: restored.id, page: 2, draft: true), BackupTestAssets.draftInk)
        XCTAssertEqual(try Data(contentsOf: target.pdfURL(for: restored.id)), try Data(contentsOf: source.pdfURL(for: original.scores[0].id)))
        var current = first; current.settings.halfPageTurns = false; try target.save(current)
        let merged = try LibraryBackup.restore(from: archive, disk: target, current: current)
        XCTAssertEqual(merged.scores.count, 2)
        XCTAssertEqual(Set(merged.scores.map(\.id)).count, 2)
        XCTAssertEqual(merged.scores[0], restored)
        XCTAssertFalse(merged.settings.halfPageTurns)
        XCTAssertEqual(merged.setlists.count, 2)
        XCTAssertEqual(try target.load(), merged)
    }
    func testCorruptBackupCannotChangeDestination() throws {
        let source = try LibraryDisk(root: folder()); let original = try fixture(source)
        let archive = try folder().appendingPathComponent("bad.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        var data = try Data(contentsOf: archive); data[data.count - 1] ^= 0xff
        try data.write(to: archive)
        let target = try LibraryDisk(root: folder()); let current = try fixture(target)
        XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: target, current: current))
        XCTAssertEqual(try target.load(), current)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.pdfDirectory.path).count, 1)
    }
    func testMissingPDFAndTruncatedArchiveAreRejected() throws {
        let source = try LibraryDisk(root: folder())
        var library = LibraryIndex(); library.scores = [.init(title: "Missing", pageCount: 1)]
        let archive = try folder().appendingPathComponent("missing.percuscorebackup")
        XCTAssertThrowsError(try LibraryBackup.export(index: library, disk: source, to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        try Data("PERCUB01".utf8).write(to: archive)
        XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: source, current: LibraryIndex()))
    }

    func testCommitFailureRollsBackNewAssets() throws {
        let source = try LibraryDisk(root: folder()); let original = try fixture(source)
        let archive = try folder().appendingPathComponent("valid.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let target = try LibraryDisk(root: folder()); let current = try fixture(target)
        // A directory at the backup-index path forces the index commit to fail.
        try FileManager.default.createDirectory(at: target.root.appendingPathComponent("library.backup.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: target, current: current))
        XCTAssertEqual(try target.load(), current)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.pdfDirectory.path).count, 1)
        XCTAssertEqual(try target.readInk(scoreID: current.scores[0].id, page: 2), BackupTestAssets.savedInk)
    }

    func testLargeAssetCrossesChunkBoundary() throws {
        let source = try LibraryDisk(root: folder()); let original = try fixture(source)
        try BackupTestAssets.writePDF(to: source.pdfURL(for: original.scores[0].id), pages: 4, padding: 2_100_123)
        let bytes = try Data(contentsOf: source.pdfURL(for: original.scores[0].id))
        XCTAssertGreaterThan(bytes.count, 2_097_152)
        let archive = try folder().appendingPathComponent("large.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let target = try LibraryDisk(root: folder())
        let restored = try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex())
        XCTAssertEqual(try Data(contentsOf: target.pdfURL(for: restored.scores[0].id)), bytes)
    }

    func testEmptyLibraryAndSettingsRoundTrip() throws {
        let source = try LibraryDisk(root: folder())
        var original = LibraryIndex(); original.settings.preventFingerDrawing = false
        let archive = try folder().appendingPathComponent("empty.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let target = try LibraryDisk(root: folder())
        XCTAssertEqual(try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex()), original)
    }

    func testDamagedHeaderAndTrailingBytesAreRejected() throws {
        let source = try LibraryDisk(root: folder()); let original = try fixture(source)
        let archive = try folder().appendingPathComponent("header.percuscorebackup")
        try LibraryBackup.export(index: original, disk: source, to: archive)
        let valid = try Data(contentsOf: archive)
        var damaged = valid; damaged[55] ^= 1; try damaged.write(to: archive)
        let target = try LibraryDisk(root: folder())
        XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex()))
        var trailing = valid; trailing.append(1); try trailing.write(to: archive)
        XCTAssertThrowsError(try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex()))
        XCTAssertTrue(try target.load().scores.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("library.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.pdfDirectory.path).count, 0)
    }

    func testInvalidReferencesAndDuplicateIDsCannotBeExported() throws {
        let source = try LibraryDisk(root: folder()); var original = try fixture(source)
        let archive = try folder().appendingPathComponent("invalid.percuscorebackup")
        original.scores.append(original.scores[0])
        XCTAssertThrowsError(try LibraryBackup.export(index: original, disk: source, to: archive))
        original.scores.removeLast()
        original.setlists[0].entries[0].scoreID = UUID()
        XCTAssertThrowsError(try LibraryBackup.export(index: original, disk: source, to: archive))
    }
}
