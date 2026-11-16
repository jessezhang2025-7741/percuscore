import XCTest
@testable import PercuscoreCore

final class ReaderWorkTests: XCTestCase {
    func testCancelledRenderRequestDoesNotRun() async {
        let worker = ReaderRenderWorker()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.run { 7 }
        }
        do { _ = try await task.value; XCTFail("Cancelled rendering must be skipped") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRenderCancelledDuringWorkDoesNotPublishResult() async {
        let worker = ReaderRenderWorker()
        let task = Task {
            try await worker.run {
                withUnsafeCurrentTask { $0?.cancel() }
                return 7
            }
        }
        do { _ = try await task.value; XCTFail("Obsolete render result must not be published") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor func testRenderingLeavesMainActorAvailable() async throws {
        let onMainThread = try await ReaderRenderWorker().run { Thread.isMainThread }
        XCTAssertFalse(onMainThread)
    }

    func testBurstPersistsFinalPositionForEachScoreWithoutReplacingOtherMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var index = LibraryIndex()
        let first = Score(title: "First", pageCount: 100)
        let second = Score(title: "Second", pageCount: 100)
        index.scores = [first, second]
        var buffer = ReadingProgressBuffer()
        let date = Date(timeIntervalSince1970: 1000)
        for page in 1...90 { buffer.record(scoreID: first.id, page: page, date: date) }
        buffer.record(scoreID: second.id, page: 12, date: date)
        buffer.record(scoreID: first.id, page: 89, date: date)
        // Metadata edited during the burst must survive the deferred progress write.
        index.scores[0].title = "Edited during reading"
        buffer.apply(to: &index)
        try disk.save(index)
        let reopened = try disk.load()
        XCTAssertEqual(reopened.scores[0].lastPage, 89)
        XCTAssertEqual(reopened.scores[1].lastPage, 12)
        XCTAssertEqual(reopened.scores[0].lastOpenedAt, date)
        XCTAssertEqual(reopened.scores[0].title, "Edited during reading")
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
    }
}
