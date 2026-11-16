import Foundation

public struct ReadingItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var scoreID: UUID
    public var title: String
    public var startPage: Int
    public var endPage: Int
    public init(id: UUID = UUID(), scoreID: UUID, title: String, startPage: Int, endPage: Int) {
        self.id = id; self.scoreID = scoreID; self.title = title
        self.startPage = startPage; self.endPage = endPage
    }
}

public struct ReadingPosition: Equatable, Sendable {
    public var itemIndex: Int
    public var page: Int
    public init(itemIndex: Int, page: Int) { self.itemIndex = itemIndex; self.page = page }
}

/// One state machine for touch, keyboard and future pedal inputs.
public struct ReadingSession: Equatable, Sendable {
    public let queue: [ReadingItem]
    public private(set) var position: ReadingPosition
    public private(set) var showingTransition = false
    public private(set) var landscapeBottom = false
    public var item: ReadingItem { queue[position.itemIndex] }

    public init?(queue: [ReadingItem], startIndex: Int = 0, page: Int? = nil) {
        guard !queue.isEmpty, queue.indices.contains(startIndex),
              queue.allSatisfy({ $0.startPage >= 0 && $0.endPage >= $0.startPage }) else { return nil }
        self.queue = queue
        let item = queue[startIndex]
        position = .init(itemIndex: startIndex, page: min(item.endPage, max(item.startPage, page ?? item.startPage)))
    }

    public func nextPosition(continueQueue: Bool) -> ReadingPosition? {
        if position.page < item.endPage {
            return .init(itemIndex: position.itemIndex, page: position.page + 1)
        }
        if continueQueue, queue.indices.contains(position.itemIndex + 1) {
            return .init(itemIndex: position.itemIndex + 1, page: queue[position.itemIndex + 1].startPage)
        }
        return nil
    }
    public func previousPosition(continueQueue: Bool) -> ReadingPosition? {
        if position.page > item.startPage { return .init(itemIndex: position.itemIndex, page: position.page - 1) }
        if continueQueue, position.itemIndex > 0 {
            return .init(itemIndex: position.itemIndex - 1, page: queue[position.itemIndex - 1].endPage)
        }
        return nil
    }

    public mutating func next(halfPage: Bool, landscape: Bool, continueQueue: Bool) {
        if landscape, !landscapeBottom { landscapeBottom = true; showingTransition = false; return }
        guard let next = nextPosition(continueQueue: continueQueue) else { return }
        if halfPage, !landscape, !showingTransition { showingTransition = true; return }
        position = next; resetStages()
    }
    public mutating func previous(halfPage: Bool, landscape: Bool, continueQueue: Bool) {
        if showingTransition { showingTransition = false; return }
        if landscape, landscapeBottom { landscapeBottom = false; return }
        guard let previous = previousPosition(continueQueue: continueQueue) else { return }
        position = previous
        showingTransition = halfPage && !landscape
        landscapeBottom = landscape
    }
    public mutating func seek(to page: Int) {
        position.page = min(item.endPage, max(item.startPage, page)); resetStages()
    }
    public mutating func resetStages() { showingTransition = false; landscapeBottom = false }
}
