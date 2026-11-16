import Foundation

public enum SaveState: Equatable { case idle, saving, saved, failed }
public enum SaveOperation: Hashable { case ink, annotation, draftCleanup, readingProgress, crop }

/// Aggregates independent writes so one successful save cannot hide another failure.
public struct SaveActivity {
    private var pending: Set<SaveOperation> = []
    private var failures: Set<SaveOperation> = []
    private var hasSaved = false
    public init() {}
    public var state: SaveState {
        if !failures.isEmpty { return .failed }
        if !pending.isEmpty { return .saving }
        return hasSaved ? .saved : .idle
    }
    public mutating func begin(_ operation: SaveOperation) {
        pending.insert(operation)
        // A new edit is not proof that a previous failed write has reached disk.
    }
    public mutating func finish(_ operation: SaveOperation) {
        pending.remove(operation); failures.remove(operation); hasSaved = true
    }
    public mutating func fail(_ operation: SaveOperation) {
        pending.remove(operation); failures.insert(operation)
    }
    public mutating func cancel(_ operation: SaveOperation) {
        pending.remove(operation); failures.remove(operation)
    }
    public func hasFailure(_ operation: SaveOperation) -> Bool { failures.contains(operation) }
    public var hasOnlyCleanupFailure: Bool { failures == [.draftCleanup] }
}

/// Serial, off-main execution for PDF preview rendering.
public actor ReaderRenderWorker {
    public init() {}
    public func run<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        let result = try operation()
        try Task.checkCancellation()
        return result
    }
}

/// A burst of turns keeps the last visit per score without saving the entire library per tap.
public struct ReadingProgressBuffer {
    private var visits: [UUID: (page: Int, date: Date)] = [:]
    private var viewports: [UUID: [Int: PageViewport]] = [:]
    public init() {}
    public var isEmpty: Bool { visits.isEmpty && viewports.isEmpty }
    public mutating func record(scoreID: UUID, page: Int, date: Date = Date()) {
        visits[scoreID] = (page, date)
    }
    public mutating func recordViewport(_ viewport: PageViewport, scoreID: UUID, page: Int) {
        var value = viewport; value.normalize()
        viewports[scoreID, default: [:]][page] = value
    }
    public func viewport(scoreID: UUID, page: Int) -> PageViewport? { viewports[scoreID]?[page] }
    public func apply(to index: inout LibraryIndex) {
        for i in index.scores.indices {
            let id = index.scores[i].id
            if let visit = visits[id] {
                index.scores[i].lastPage = min(max(0, visit.page), max(0, index.scores[i].pageCount - 1))
                index.scores[i].lastOpenedAt = visit.date
            }
            for (page, viewport) in viewports[id] ?? [:] where (0..<index.scores[i].pageCount).contains(page) {
                index.scores[i].viewports[page] = viewport
            }
        }
    }
    public mutating func removeAll() { visits.removeAll(); viewports.removeAll() }
}
