import XCTest
@testable import Percuscore

@MainActor
final class ExcerptIdentityTests: XCTestCase {
    private func folder() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExcerptIdentity-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func fixture() throws -> (LibraryDisk, LibraryIndex, URL) {
        let disk = try LibraryDisk(root: folder())
        var score = Score(title: "Original", pageCount: 4)
        score.bookmarks = [.init(title: "Finale", startPage: 2, endPage: 3)]
        var library = LibraryIndex(); library.scores = [score]
        var setlist = ScoreSetlist(title: "Rehearsal")
        setlist.entries = [.init(scoreID: score.id, bookmarkID: score.bookmarks[0].id)]
        library.setlists = [setlist]
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        try disk.save(library)
        let archive = disk.root.appendingPathComponent("original.percuscorebackup")
        try LibraryBackup.export(index: library, disk: disk, to: archive)
        return (disk, library, archive)
    }
    func testRepeatedRestoreIntoEmptyLibraryHasDistinctExcerptRows() throws {
        let (_, original, archive) = try fixture()
        let target = try LibraryDisk(root: folder())
        let first = try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex())
        let second = try LibraryBackup.restore(from: archive, disk: target, current: first)
        let rows = LibraryExcerpt.items(in: try target.load().scores)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "Both restored excerpts must have their own SwiftUI identity")
        XCTAssertEqual(Set(second.scores.map(\.id)).count, 2)
        // Bookmark UUIDs are score-scoped: portable references remain unchanged.
        XCTAssertTrue(second.scores.allSatisfy { $0.bookmarks == original.scores[0].bookmarks })
        for list in second.setlists {
            let item = try XCTUnwrap(second.resolve(list.entries[0]))
            XCTAssertEqual(item.startPage, 2); XCTAssertEqual(item.endPage, 3)
            XCTAssertEqual(item.scoreID, list.entries[0].scoreID)
        }
    }
    func testRestoringAlongsideOriginalKeepsEachRowAssociatedWithItsOwnScore() throws {
        let (disk, original, archive) = try fixture()
        let first = try LibraryBackup.restore(from: archive, disk: disk, current: original)
        let second = try LibraryBackup.restore(from: archive, disk: disk, current: first)
        let rows = LibraryExcerpt.items(in: second.scores)
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        // Looking up a row by the identity consumed by ForEach must select that score.
        for row in rows {
            let identified = try XCTUnwrap(rows.first { $0.id == row.id })
            let entry = SetlistEntry(scoreID: identified.score.id, bookmarkID: identified.bookmark.id)
            let selected = try XCTUnwrap(second.resolve(entry))
            XCTAssertEqual(selected.scoreID, row.score.id)
            XCTAssertEqual(selected.startPage, 2); XCTAssertEqual(selected.endPage, 3)
        }
        XCTAssertEqual(second.scores[0], original.scores[0])
        XCTAssertEqual(second.setlists[0], original.setlists[0])
    }
    func testAlreadyStoredSharedBookmarkIDsStayDistinctAfterReloadAndResolveCorrectRanges() throws {
        let (disk, original, _) = try fixture()
        var library = original, other = original.scores[0]
        other.id = UUID(); other.title = "Other"
        other.bookmarks[0].startPage = 0; other.bookmarks[0].endPage = 1
        library.scores.append(other)
        try SampleScore.write(to: disk.pdfURL(for: other.id)); try disk.save(library)
        let loaded = try disk.load(), rows = LibraryExcerpt.items(in: loaded.scores)
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        for (offset, expectedStart) in [2, 0].enumerated() {
            let row = try XCTUnwrap(rows.first { $0.id == rows[offset].id })
            let selected = try XCTUnwrap(loaded.resolve(.init(scoreID: row.score.id, bookmarkID: row.bookmark.id)))
            XCTAssertEqual(selected.startPage, expectedStart)
        }
    }
    func testExcerptIdentityIsStableAcrossSortingAndMetadataEditsAndExcludesPageBookmarks() throws {
        let (_, original, _) = try fixture()
        var score = original.scores[0]
        score.bookmarks.append(.init(title: "Cue", startPage: 1))
        score.bookmarks.append(.init(title: "Intro", startPage: 0, endPage: 1))
        let before = LibraryExcerpt.items(in: [score])
        XCTAssertEqual(before.count, 2); XCTAssertEqual(Set(before.map(\.id)).count, 2)
        score.title = "Renamed"; score.bookmarks[0].title = "New title"
        score.bookmarks.reverse()
        let after = LibraryExcerpt.items(in: [score])
        XCTAssertEqual(after.map(\.id), before.map(\.id).reversed())
        XCTAssertEqual(LibraryExcerpt.items(in: []).count, 0)
    }
}
