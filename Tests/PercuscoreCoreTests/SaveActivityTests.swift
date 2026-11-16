import XCTest
@testable import PercuscoreCore

final class SaveActivityTests: XCTestCase {
    func testPendingWritesRemainSavingUntilEveryOperationFinishes() {
        var saves = SaveActivity()
        XCTAssertEqual(saves.state, .idle)
        saves.begin(.ink); saves.begin(.readingProgress)
        XCTAssertEqual(saves.state, .saving)
        saves.finish(.ink)
        XCTAssertEqual(saves.state, .saving)
        saves.finish(.readingProgress)
        XCTAssertEqual(saves.state, .saved)
    }

    func testSuccessfulOtherWriteCannotHideFailureAndRetryClearsOnlyItsOwnFailure() {
        var saves = SaveActivity()
        saves.begin(.ink); saves.begin(.readingProgress)
        saves.fail(.ink); saves.finish(.readingProgress)
        XCTAssertEqual(saves.state, .failed)
        saves.fail(.crop); saves.begin(.ink)
        XCTAssertEqual(saves.state, .failed)
        saves.finish(.ink)
        XCTAssertEqual(saves.state, .failed)
        saves.begin(.crop)
        XCTAssertEqual(saves.state, .failed)
        saves.finish(.crop)
        XCTAssertEqual(saves.state, .saved)
    }

    func testCancellingAnEditDoesNotHideAnUnrelatedFailure() {
        var saves = SaveActivity()
        saves.begin(.ink); saves.cancel(.ink)
        XCTAssertEqual(saves.state, .idle)
        saves.fail(.readingProgress); saves.begin(.ink); saves.cancel(.ink)
        XCTAssertEqual(saves.state, .failed)
    }
    func testCleanupFailureIsDistinctFromConfirmationAndOtherFailures() {
        var saves = SaveActivity()
        saves.finish(.annotation); saves.fail(.draftCleanup)
        XCTAssertTrue(saves.hasOnlyCleanupFailure)
        XCTAssertFalse(saves.hasFailure(.annotation))
        saves.fail(.readingProgress)
        XCTAssertFalse(saves.hasOnlyCleanupFailure)
        saves.finish(.draftCleanup)
        XCTAssertEqual(saves.state, .failed)
        XCTAssertTrue(saves.hasFailure(.readingProgress))
    }
}
