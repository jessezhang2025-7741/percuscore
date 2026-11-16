import Foundation

public enum LibrarySort: String, CaseIterable, Sendable {
    case title, composer, lastOpened, imported

    /// Unknown composers and unread scores stay last in both directions.
    /// Equal values use title and identity so reloads do not shuffle the library.
    public func arranged(_ scores: [Score], ascending: Bool) -> [Score] {
        scores.sorted { left, right in
            let comparison: ComparisonResult
            switch self {
            case .title:
                comparison = left.title.localizedStandardCompare(right.title)
            case .composer:
                let lhs = left.composer.trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = right.composer.trimmingCharacters(in: .whitespacesAndNewlines)
                if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
                comparison = lhs.localizedStandardCompare(rhs)
            case .lastOpened:
                if (left.lastOpenedAt == nil) != (right.lastOpenedAt == nil) { return left.lastOpenedAt != nil }
                comparison = (left.lastOpenedAt ?? .distantPast).compare(right.lastOpenedAt ?? .distantPast)
            case .imported:
                comparison = left.importedAt.compare(right.importedAt)
            }
            if comparison != .orderedSame {
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }
            let titleComparison = left.title.localizedStandardCompare(right.title)
            if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
            return left.id.uuidString < right.id.uuidString
        }
    }
}
