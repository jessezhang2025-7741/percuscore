import XCTest
@testable import PercuscoreCore

final class MetadataTests: XCTestCase {
    func testLegacyScoreAndMetadataRoundTrip() throws {
        let score = Score(title: "Symphony 5", pageCount: 4)
        let data = try JSONEncoder().encode(score)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "composer")
        json.removeValue(forKey: "part")
        json.removeValue(forKey: "tags")
        var restored = try JSONDecoder().decode(Score.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.composer, "")
        XCTAssertEqual(restored.tags, [])
        restored.composer = "Gustav Mahler"
        restored.part = "Timpani"
        restored.tags = ["Audition", "Orchestra"]
        XCTAssertEqual(try JSONDecoder().decode(Score.self, from: JSONEncoder().encode(restored)), restored)
    }
    func testSearchAcrossFieldsRequiresEveryTerm() {
        var score = Score(title: "Symphony 5", pageCount: 4)
        score.composer = "Gustav Mahler"
        score.part = "Timpani"
        score.tags = ["Audition", "管弦乐"]
        XCTAssertTrue(score.matchesSearch(" MAHLER + timpani "))
        XCTAssertTrue(score.matchesSearch("管弦乐 5"))
        XCTAssertTrue(score.matchesSearch("audition"))
        XCTAssertTrue(score.matchesSearch("  "))
        XCTAssertFalse(score.matchesSearch("Mahler Snare"))
    }

    func testMetadataOnDiskPreservesScoreAssetsAndReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var score = Score(title: "Old title", pageCount: 4)
        score.lastPage = 2
        score.bookmarks = [.init(title: "Finale", startPage: 2, endPage: 3)]
        var layout = PageLayout(); layout.scale = 1.4
        score.layouts[2] = layout
        var library = LibraryIndex(); library.scores = [score]
        var setlist = ScoreSetlist(title: "Concert")
        setlist.entries = [.init(scoreID: score.id), .init(scoreID: score.id, bookmarkID: score.bookmarks[0].id)]
        library.setlists = [setlist]
        let pdf = Data("%PDF-test-fixture".utf8), ink = Data([1, 2, 3])
        try pdf.write(to: disk.pdfURL(for: score.id))
        try disk.writeInk(ink, scoreID: score.id, page: 2)
        try disk.save(library)
        library.scores[0].title = "Symphony 5"
        library.scores[0].composer = "Mahler"
        library.scores[0].part = "Timpani"
        library.scores[0].tags = ["Concert"]
        try disk.save(library)
        let reopenedDisk = try LibraryDisk(root: root)
        let reopened = try reopenedDisk.load()
        XCTAssertEqual(reopened, library)
        XCTAssertEqual(reopened.resolve(setlist.entries[0])?.title, "Symphony 5")
        XCTAssertEqual(reopened.resolve(setlist.entries[1])?.startPage, 2)
        XCTAssertEqual(try Data(contentsOf: reopenedDisk.pdfURL(for: score.id)), pdf)
        XCTAssertEqual(try reopenedDisk.readInk(scoreID: score.id, page: 2), ink)
        XCTAssertTrue(reopened.scores[0].matchesSearch("Mahler + Timpani"))
    }

    func testSearchSeparatesPartsAndSupportsAccentsAndExcerpts() {
        var timpani = Score(title: "Symphony 5", pageCount: 4)
        timpani.composer = "Mahler"; timpani.part = "Timpani"
        var snare = timpani; snare.id = UUID(); snare.part = "Snare"
        XCTAssertEqual([timpani, snare].filter { $0.matchesSearch("Mahler Timpani") }.map(\.id), [timpani.id])
        XCTAssertFalse(timpani.matchesSearch("Beethoven Timpani"))
        XCTAssertTrue(timpani.matchesSearch("Mahler Finale", additionalText: "Finale"))
        XCTAssertFalse(timpani.matchesSearch("Mahler Finale"))
        var french = Score(title: "Étude", pageCount: 1)
        french.composer = "Fauré"
        XCTAssertTrue(french.matchesSearch("etude FAURE"))
    }
}
