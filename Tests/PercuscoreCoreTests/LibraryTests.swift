import XCTest
@testable import PercuscoreCore

final class LibraryTests: XCTestCase {
    private func disk() throws -> LibraryDisk {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PercuscoreTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LibraryDisk(root: root)
    }
    func testAllMetadataSurvivesRelaunch() throws {
        let disk = try disk()
        var library = LibraryIndex()
        var score = Score(title: "Mahler – Timpani", pageCount: 48)
        let item = ScoreBookmark(title: "Movement III", startPage: 24, endPage: 34)
        score.bookmarks = [item, .init(title: "Rehearsal 37", startPage: 28)]
        var layout = PageLayout(); layout.scale = 1.3; layout.offsetY = -0.1; layout.rotation = 1.2; layout.divider = 0.4
        score.layouts[28] = layout; score.lastPage = 28; score.isFavorite = true
        library.scores = [score]
        var setlist = ScoreSetlist(title: "Fall concert")
        setlist.entries = [.init(scoreID: score.id, bookmarkID: item.id)]
        library.setlists = [setlist]; library.settings.halfPageTurns = true
        try disk.save(library)
        let reopened = try LibraryDisk(root: disk.root).load()
        XCTAssertEqual(reopened, library)
        XCTAssertEqual(reopened.resolve(setlist.entries[0])?.startPage, 24)
        XCTAssertEqual(reopened.resolve(setlist.entries[0])?.endPage, 34)
    }
    func testImportIsACopyAndInkDoesNotChangePDF() throws {
        let disk = try disk(), id = UUID()
        let original = disk.root.appendingPathComponent("source.pdf")
        let bytes = Data("%PDF-original-fixture".utf8)
        try bytes.write(to: original); try disk.copyPDF(from: original, scoreID: id)
        try Data("changed-source".utf8).write(to: original)
        try disk.writeInk(Data([1, 2, 3]), scoreID: id, page: 0)
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: id)), bytes)
    }
    func testDraftAndCommittedInkAreIndependent() throws {
        let disk = try disk(), id = UUID()
        try disk.writeInk(Data([1]), scoreID: id, page: 2)
        try disk.writeInk(Data([9]), scoreID: id, page: 2, draft: true)
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 2), Data([1]))
        XCTAssertEqual(try LibraryDisk(root: disk.root).readInk(scoreID: id, page: 2, draft: true), Data([9]))
        try disk.discardDraft(scoreID: id, page: 2)
        XCTAssertNil(try disk.readInk(scoreID: id, page: 2, draft: true))
        XCTAssertEqual(try disk.readInk(scoreID: id, page: 2), Data([1]))
    }
    func testInkIsIsolatedByScoreAndPage() throws {
        let disk = try disk(), a = UUID(), b = UUID()
        try disk.writeInk(Data([1]), scoreID: a, page: 0)
        try disk.writeInk(Data([2]), scoreID: a, page: 1)
        try disk.writeInk(Data([3]), scoreID: b, page: 0)
        XCTAssertEqual(try disk.readInk(scoreID: a, page: 0), Data([1]))
        XCTAssertEqual(try disk.readInk(scoreID: a, page: 1), Data([2]))
        XCTAssertEqual(try disk.readInk(scoreID: b, page: 0), Data([3]))
    }
    func testCorruptionRecoversPreviousIndexAndPreservesDamagedFile() throws {
        let disk = try disk()
        var first = LibraryIndex(); first.scores = [.init(title: "A", pageCount: 2)]
        try disk.save(first)
        var second = first; second.scores.append(.init(title: "B", pageCount: 3)); try disk.save(second)
        try Data("broken".utf8).write(to: disk.root.appendingPathComponent("library.json"))
        let reopened = try LibraryDisk(root: disk.root)
        XCTAssertEqual(try reopened.load(), first); XCTAssertTrue(reopened.recoveredFromBackup)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: disk.root.path).contains { $0.hasPrefix("library-damaged-") })
    }
    func testCorruptionWithoutBackupDoesNotSilentlyResetLibrary() throws {
        let disk = try disk()
        try Data("broken".utf8).write(to: disk.root.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try disk.load())
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), Data("broken".utf8))
    }
    func testFutureVersionDoesNotRollBackToOldBackup() throws {
        let disk = try disk(); try disk.save(LibraryIndex())
        try disk.save(LibraryIndex())
        var next = LibraryIndex(); next.version = 999
        // Model a file written by a future app; current save now rejects unknown versions.
        try JSONEncoder().encode(next).write(to: disk.root.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try disk.load()) { error in
            guard case LibraryError.unsupportedVersion = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
    func testDeletingReferencesDoesNotDuplicateOrDeleteOtherScores() {
        var library = LibraryIndex()
        var score = Score(title: "Excerpts", pageCount: 20)
        let bookmark = ScoreBookmark(title: "A", startPage: 2, endPage: 4); score.bookmarks = [bookmark]
        library.scores = [score]
        for title in ["Concert", "Lesson"] {
            var list = ScoreSetlist(title: title)
            list.entries = [.init(scoreID: score.id), .init(scoreID: score.id, bookmarkID: bookmark.id)]
            library.setlists.append(list)
        }
        XCTAssertEqual(library.scores.count, 1)
        library.removeBookmark(scoreID: score.id, bookmarkID: bookmark.id)
        XCTAssertTrue(library.setlists.allSatisfy { $0.entries.count == 1 })
        XCTAssertEqual(library.scores.count, 1)
        library.removeScore(score.id)
        XCTAssertTrue(library.setlists.allSatisfy { $0.entries.count == 1 })
        XCTAssertTrue(library.activeScores.isEmpty)
    }
    func testPageBookmarksCannotBeUsedAsSetlistItems() {
        var library = LibraryIndex(); var score = Score(title: "A", pageCount: 10)
        let bookmark = ScoreBookmark(title: "Jump", startPage: 4); score.bookmarks = [bookmark]; library.scores = [score]
        XCTAssertNil(library.resolve(.init(scoreID: score.id, bookmarkID: bookmark.id)))
        XCTAssertNotNil(library.resolve(.init(scoreID: score.id)))
    }
    func testBookmarkValidation() {
        XCTAssertFalse(ScoreBookmark(title: " ", startPage: 0).isValid(pageCount: 10))
        XCTAssertFalse(ScoreBookmark(title: "A", startPage: -1).isValid(pageCount: 10))
        XCTAssertFalse(ScoreBookmark(title: "A", startPage: 10).isValid(pageCount: 10))
        XCTAssertFalse(ScoreBookmark(title: "A", startPage: 5, endPage: 4).isValid(pageCount: 10))
        XCTAssertTrue(ScoreBookmark(title: "A", startPage: 0, endPage: 9).isValid(pageCount: 10))
    }
    func testCropAndDividerClampInvalidValues() {
        var layout = PageLayout()
        layout.scale = .infinity; layout.offsetX = .nan; layout.offsetY = 90
        layout.rotation = -99; layout.divider = 0
        layout.normalize()
        XCTAssertEqual(layout.scale, 1); XCTAssertEqual(layout.offsetX, 0); XCTAssertEqual(layout.offsetY, 1)
        XCTAssertEqual(layout.rotation, -10); XCTAssertEqual(layout.divider, 0.25)
    }
}
