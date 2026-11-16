import XCTest
@testable import PercuscoreCore

final class DiagnosticLogTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func event(_ page: Int) -> ReaderDiagnosticEvent {
        ReaderDiagnosticEvent(kind: .pageLoaded, state: .succeeded, page: page, item: 0, durationMS: 2)
    }
    func testLogBoundsBytesAndEntriesAcrossReopen() throws {
        let url = try root().appendingPathComponent("events.json")
        let log = BoundedDiagnosticLog(url: url, maximumBytes: 4096, maximumEntries: 10)
        for p in 0..<100 { log.record(event(p)) }
        try log.flush()
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 4096)
        let restored = BoundedDiagnosticLog(url: url, maximumBytes: 4096, maximumEntries: 10)
        let events = try restored.snapshot()
        XCTAssertLessThanOrEqual(events.count, 10)
        XCTAssertEqual(events.last?.page, 99)
    }
    func testSchemaHasNoArbitraryTextContentAndInvalidDurationsAreRemoved() throws {
        var e = event(1); e.durationMS = .infinity
        let url = try root().appendingPathComponent("events.json")
        let log = BoundedDiagnosticLog(url: url)
        log.record(e); try log.flush()
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        XCTAssertNil(records[0]["durationMS"])
        XCTAssertFalse(records[0].keys.contains("title"))
        XCTAssertFalse(records[0].keys.contains("drawing"))
        XCTAssertFalse(records[0].keys.contains("path"))
    }
    func testOversizedOrCorruptPreviousLogIsNeverLoaded() throws {
        let url = try root().appendingPathComponent("events.json")
        try Data(repeating: 65, count: 6000).write(to: url)
        let log = BoundedDiagnosticLog(url: url, maximumBytes: 4096)
        XCTAssertTrue(try log.snapshot().isEmpty)
        log.record(event(2)); try log.flush()
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 4096)
    }
    func testClearRemovesPersistedEvents() throws {
        let url = try root().appendingPathComponent("events.json")
        let log = BoundedDiagnosticLog(url: url)
        log.record(event(2)); try log.flush(); try log.clear()
        XCTAssertTrue(try log.snapshot().isEmpty)
        XCTAssertTrue(try BoundedDiagnosticLog(url: url).snapshot().isEmpty)
    }
    func testWriteFailureIsReportedWithoutDiscardingMemoryEvidence() throws {
        let root = try root()
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        let log = BoundedDiagnosticLog(url: blocker.appendingPathComponent("events.json"))
        log.record(event(5))
        XCTAssertThrowsError(try log.flush())
        XCTAssertEqual(try log.snapshot().last?.page, 5)
    }
}
