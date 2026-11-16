import XCTest
import UIKit
import PDFKit
@testable import Percuscore

@MainActor
final class IndexSafetyTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, Score) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexSafety-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), score = Score(title: "Index safety", pageCount: 2)
        let disk = try XCTUnwrap(store.disk)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            .writePDF(to: disk.pdfURL(for: score.id)) { context in
                context.beginPage(); context.beginPage()
            }
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings.halfPageTurns = true })
        XCTAssertTrue(store.update { $0.scores[0].lastOpenedAt = Date() })
        return (store, score)
    }
    func testInvalidLocalIndexLeavesStoreUnavailableAndPreservesFiles() throws {
        let (store, score) = try fixture(), disk = try XCTUnwrap(store.disk)
        var invalid = store.index; invalid.scores[0].lastPage = Int.max
        invalid.scores[0].lastOpenedAt = Date()
        let bytes = try JSONEncoder().encode(invalid)
        try bytes.write(to: disk.root.appendingPathComponent("library.json"))
        try FileManager.default.removeItem(at: disk.root.appendingPathComponent("library.backup.json"))
        let reopened = LibraryStore(root: disk.root)
        XCTAssertFalse(reopened.isReady)
        XCTAssertTrue(reopened.index.scores.isEmpty)
        XCTAssertNotNil(reopened.errorMessage)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.pdfURL(for: score.id).path))
        XCTAssertFalse(reopened.update { $0.scores.removeAll() })
    }
    func testInvalidUpdateKeepsPublishedIndexAndBothDiskCopies() throws {
        let (store, _) = try fixture(), disk = try XCTUnwrap(store.disk), valid = store.index
        let primary = try Data(contentsOf: disk.root.appendingPathComponent("library.json"))
        let backup = try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json"))
        XCTAssertFalse(store.update { $0.scores[0].lastPage = Int.max })
        XCTAssertEqual(store.index, valid)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), primary)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json")), backup)
    }
    func testRecoveredIndexCanOpenHalfPageReader() throws {
        let (store, score) = try fixture(), disk = try XCTUnwrap(store.disk), valid = store.index
        try JSONEncoder().encode(valid).write(to: disk.root.appendingPathComponent("library.backup.json"))
        var invalid = valid; invalid.scores[0].lastPage = Int.max
        try JSONEncoder().encode(invalid).write(to: disk.root.appendingPathComponent("library.json"))
        let reopened = LibraryStore(root: disk.root)
        XCTAssertTrue(reopened.isReady); XCTAssertEqual(reopened.index, valid)
        XCTAssertNotNil(reopened.errorMessage)
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 1)]))
        let model = ReaderModel(store: reopened, session: session)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 834, height: 1100)
        model.turn(forward: true); surface.refresh(); surface.layoutIfNeeded()
        XCTAssertNotNil(model.page); XCTAssertTrue(model.session.showingTransition)
    }
    func testDividerDisplayBoundsTransientOutOfRangeValue() throws {
        let (store, score) = try fixture()
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 1)]))
        let model = ReaderModel(store: store, session: session)
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.frame = CGRect(x: 0, y: 0, width: 834, height: 1100)
        model.turn(forward: true)
        func divider(in view: UIView) -> UIView? {
            if view.accessibilityLabel == "Half-page divider" { return view }
            return view.subviews.lazy.compactMap { divider(in: $0) }.first
        }
        let values: [(Double, String)] = [(2, "75"), (-1, "25"), (1e100, "75"),
            (.nan, "50"), (.infinity, "50"), (-.infinity, "50"), (0.4, "40")]
        for (value, percent) in values {
            model.layout.divider = value
            surface.refresh(); surface.layoutIfNeeded()
            let view = try XCTUnwrap(divider(in: surface))
            XCTAssertEqual(view.accessibilityValue, "\(percent) percent from top")
            XCTAssertTrue(view.frame.minY.isFinite && view.frame.maxY.isFinite)
        }
    }
    func testConvertingItemBookmarkToPageRemovesOnlyItsSetlistReferences() throws {
        let (store, score) = try fixture()
        var bookmark = ScoreBookmark(title: "Excerpt", startPage: 0, endPage: 1)
        XCTAssertTrue(store.update { index in
            index.scores[0].bookmarks = [bookmark]
            for title in ["Concert", "Practice"] {
                var list = ScoreSetlist(title: title)
                list.entries = [.init(scoreID: score.id, bookmarkID: bookmark.id), .init(scoreID: score.id)]
                index.setlists.append(list)
            }
        })
        let retainedIDs = store.index.setlists.map { $0.entries[1].id }
        bookmark.endPage = nil
        XCTAssertTrue(store.saveBookmark(bookmark, scoreID: score.id))
        XCTAssertEqual(store.index.scores[0].bookmarks, [bookmark])
        XCTAssertEqual(store.index.setlists.map { $0.entries.map(\.id) }, retainedIDs.map { [$0] })
        XCTAssertEqual(try LibraryDisk(root: XCTUnwrap(store.disk).root).load(), store.index)
    }
}
