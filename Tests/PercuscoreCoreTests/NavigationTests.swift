import XCTest
@testable import PercuscoreCore

final class NavigationTests: XCTestCase {
    private let scoreA = UUID(), scoreB = UUID()
    private func queue() -> [ReadingItem] {
        [.init(scoreID: scoreA, title: "A", startPage: 0, endPage: 2),
         .init(scoreID: scoreB, title: "Excerpt", startPage: 12, endPage: 14)]
    }

    func testOrdinaryTurnsTraverseSetlistAndExcerptBounds() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue()))
        for _ in 0..<3 { session.next(halfPage: false, landscape: false, continueQueue: true) }
        XCTAssertEqual(session.position, .init(itemIndex: 1, page: 12))
        session.previous(halfPage: false, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position, .init(itemIndex: 0, page: 2))
    }
    func testHalfTurnHasTwoReversibleStages() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue()))
        session.next(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position.page, 0); XCTAssertTrue(session.showingTransition)
        session.next(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position.page, 1); XCTAssertFalse(session.showingTransition)
        session.previous(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position.page, 0); XCTAssertTrue(session.showingTransition)
        session.previous(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position.page, 0); XCTAssertFalse(session.showingTransition)
    }
    func testHalfTurnAcrossItemsUsesNextExcerptStart() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue(), page: 2))
        session.next(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.nextPosition(continueQueue: true), .init(itemIndex: 1, page: 12))
        XCTAssertTrue(session.showingTransition)
        session.next(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position, .init(itemIndex: 1, page: 12))
    }
    func testQueueContinuationDisabledStopsAtBoundary() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue(), page: 2))
        session.next(halfPage: true, landscape: false, continueQueue: false)
        XCTAssertEqual(session.position.page, 2); XCTAssertFalse(session.showingTransition)
    }
    func testNoPhantomHalfPageAfterLastPage() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue(), startIndex: 1, page: 14))
        session.next(halfPage: true, landscape: false, continueQueue: true)
        XCTAssertEqual(session.position.page, 14); XCTAssertFalse(session.showingTransition)
    }
    func testLandscapeShowsTopThenBottomThenNextTop() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue()))
        session.next(halfPage: true, landscape: true, continueQueue: true)
        XCTAssertTrue(session.landscapeBottom); XCTAssertFalse(session.showingTransition)
        XCTAssertEqual(session.position.page, 0)
        session.next(halfPage: true, landscape: true, continueQueue: true)
        XCTAssertFalse(session.landscapeBottom); XCTAssertEqual(session.position.page, 1)
        session.previous(halfPage: true, landscape: true, continueQueue: true)
        XCTAssertEqual(session.position.page, 0); XCTAssertTrue(session.landscapeBottom)
    }
    func testLastLandscapePageStillShowsBottom() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue(), startIndex: 1, page: 14))
        session.next(halfPage: false, landscape: true, continueQueue: true)
        XCTAssertTrue(session.landscapeBottom)
        session.next(halfPage: false, landscape: true, continueQueue: true)
        XCTAssertEqual(session.position.page, 14); XCTAssertTrue(session.landscapeBottom)
    }
    func testSeekClampsAndClearsTransitionStages() throws {
        var session = try XCTUnwrap(ReadingSession(queue: queue(), startIndex: 1))
        session.next(halfPage: true, landscape: false, continueQueue: true)
        session.seek(to: 999)
        XCTAssertEqual(session.position.page, 14); XCTAssertFalse(session.showingTransition)
        session.seek(to: -100)
        XCTAssertEqual(session.position.page, 12)
    }
    func testInvalidQueuesAreRejectedAndInitialPageClamped() {
        XCTAssertNil(ReadingSession(queue: []))
        XCTAssertNil(ReadingSession(queue: queue(), startIndex: 10))
        XCTAssertNil(ReadingSession(queue: [.init(scoreID: scoreA, title: "Bad", startPage: 9, endPage: 3)]))
        XCTAssertEqual(ReadingSession(queue: queue(), page: 90)?.position.page, 2)
    }
    func testTraversalAlwaysRemainsInBounds() throws {
        for half in [true, false] {
            for landscape in [true, false] {
                for continuation in [true, false] {
                    var session = try XCTUnwrap(ReadingSession(queue: queue()))
                    for step in 0..<200 {
                        if step % 7 < 4 { session.next(halfPage: half, landscape: landscape, continueQueue: continuation) }
                        else { session.previous(halfPage: half, landscape: landscape, continueQueue: continuation) }
                        XCTAssertTrue(session.item.startPage...session.item.endPage ~= session.position.page)
                        XCTAssertFalse(session.showingTransition && session.landscapeBottom)
                    }
                }
            }
        }
    }
}
