import XCTest
@testable import PercuscoreCore

final class LibrarySortTests: XCTestCase {
    private func score(_ title: String, composer: String = "", imported: Double = 0, opened: Double? = nil,
                       id: String = "00000000-0000-0000-0000-000000000001") -> Score {
        var score = Score(id: UUID(uuidString: id)!, title: title, pageCount: 4)
        score.composer = composer
        score.importedAt = Date(timeIntervalSince1970: imported)
        score.lastOpenedAt = opened.map { Date(timeIntervalSince1970: $0) }
        return score
    }

    func testTitleSortUsesNaturalNumbersAndSupportsReverseOrder() {
        let scores = [score("Study 10"), score("Study 2"), score("Study 1")]
        XCTAssertEqual(LibrarySort.title.arranged(scores, ascending: true).map(\.title), ["Study 1", "Study 2", "Study 10"])
        XCTAssertEqual(LibrarySort.title.arranged(scores, ascending: false).map(\.title), ["Study 10", "Study 2", "Study 1"])
    }

    func testComposerSortPlacesUnknownComposersLastInEitherDirection() {
        let scores = [score("Unknown", composer: "  "), score("Z", composer: "Bach"),
                      score("A", composer: "Bach"), score("M", composer: "Mahler")]
        XCTAssertEqual(LibrarySort.composer.arranged(scores, ascending: true).map(\.title), ["A", "Z", "M", "Unknown"])
        XCTAssertEqual(LibrarySort.composer.arranged(scores, ascending: false).map(\.title), ["M", "A", "Z", "Unknown"])
    }

    func testLastOpenedSortPlacesUnreadScoresLast() {
        let scores = [score("Unread"), score("Older", opened: 10), score("Latest", opened: 30)]
        XCTAssertEqual(LibrarySort.lastOpened.arranged(scores, ascending: false).map(\.title), ["Latest", "Older", "Unread"])
        XCTAssertEqual(LibrarySort.lastOpened.arranged(scores, ascending: true).map(\.title), ["Older", "Latest", "Unread"])
    }

    func testImportDateSortSupportsNewestAndOldestFirst() {
        let scores = [score("Middle", imported: 20), score("Old", imported: 10), score("New", imported: 30)]
        XCTAssertEqual(LibrarySort.imported.arranged(scores, ascending: false).map(\.title), ["New", "Middle", "Old"])
        XCTAssertEqual(LibrarySort.imported.arranged(scores, ascending: true).map(\.title), ["Old", "Middle", "New"])
    }

    func testEqualValuesHaveStableTitleAndIdentityOrderWithoutChangingSources() {
        let first = score("Same", imported: 20)
        let second = score("Same", imported: 20, id: "00000000-0000-0000-0000-000000000002")
        let alpha = score("Alpha", imported: 20, id: "00000000-0000-0000-0000-000000000003")
        let scores = [second, first, alpha]
        XCTAssertEqual(LibrarySort.imported.arranged(scores, ascending: false).map(\.id), [alpha.id, first.id, second.id])
        XCTAssertEqual(LibrarySort.imported.arranged(Array(scores.reversed()), ascending: false).map(\.id), [alpha.id, first.id, second.id])
        XCTAssertEqual(scores.map(\.id), [second.id, first.id, alpha.id])
    }
}
