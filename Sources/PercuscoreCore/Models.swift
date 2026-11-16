import Foundation

/// Manual reading view, independent of the saved Crop and editable ink coordinates.
public struct PageViewport: Codable, Equatable, Sendable {
    public var scale: Double = 1
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public init() {}
    public mutating func normalize() {
        scale = scale.isFinite ? min(4, max(1, scale)) : 1
        let limit = (scale - 1) / 2
        offsetX = offsetX.isFinite ? min(limit, max(-limit, offsetX)) : 0
        offsetY = offsetY.isFinite ? min(limit, max(-limit, offsetY)) : 0
    }
    public func applying(to layout: PageLayout) -> PageLayout {
        var result = layout
        result.scale *= scale
        result.offsetX += offsetX; result.offsetY += offsetY
        return result
    }
}

public struct PageLayout: Codable, Equatable, Sendable {
    public var scale: Double = 1
    /// Offsets are fractions of the displayed page size, independent of screen size.
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var rotation: Double = 0
    public var divider: Double = 0.5
    public init() {}

    /// UI and accessibility conversions must also tolerate transient invalid state.
    public var boundedDivider: Double {
        divider.isFinite ? min(0.75, max(0.25, divider)) : 0.5
    }
    public var dividerPercentage: Int { Int((boundedDivider * 100).rounded()) }

    public mutating func normalize() {
        scale = scale.isFinite ? min(3, max(1, scale)) : 1
        offsetX = offsetX.isFinite ? min(1, max(-1, offsetX)) : 0
        offsetY = offsetY.isFinite ? min(1, max(-1, offsetY)) : 0
        rotation = rotation.isFinite ? min(10, max(-10, rotation)) : 0
        divider = boundedDivider
    }
}

public struct ScoreBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startPage: Int
    /// nil means a page bookmark; a value means an item bookmark (inclusive range).
    public var endPage: Int?
    public var isItem: Bool { endPage != nil }
    public init(id: UUID = UUID(), title: String, startPage: Int, endPage: Int? = nil) {
        self.id = id; self.title = title; self.startPage = startPage; self.endPage = endPage
    }
    public func isValid(pageCount: Int) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        startPage >= 0 && startPage < pageCount &&
        (endPage == nil || (endPage! >= startPage && endPage! < pageCount))
    }
}

public struct Score: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var pageCount: Int
    public var importedAt: Date
    public var lastOpenedAt: Date?
    public var lastPage: Int = 0
    public var isFavorite: Bool = false
    public var bookmarks: [ScoreBookmark] = []
    public var layouts: [Int: PageLayout] = [:]
    public var viewports: [Int: PageViewport] = [:]
    public var composer: String = ""
    public var part: String = ""
    public var tags: [String] = []
    public var deletedAt: Date?
    public var purgePendingAt: Date?
    public var isDeleted: Bool { deletedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, pageCount, importedAt, lastOpenedAt, lastPage, isFavorite, bookmarks, layouts
        case composer, part, tags, viewports, deletedAt, purgePendingAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        lastPage = try c.decodeIfPresent(Int.self, forKey: .lastPage) ?? 0
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        bookmarks = try c.decodeIfPresent([ScoreBookmark].self, forKey: .bookmarks) ?? []
        layouts = try c.decodeIfPresent([Int: PageLayout].self, forKey: .layouts) ?? [:]
        viewports = try c.decodeIfPresent([Int: PageViewport].self, forKey: .viewports) ?? [:]
        composer = try c.decodeIfPresent(String.self, forKey: .composer) ?? ""
        part = try c.decodeIfPresent(String.self, forKey: .part) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        purgePendingAt = try c.decodeIfPresent(Date.self, forKey: .purgePendingAt)
    }

    public func matchesSearch(_ query: String, additionalText: String = "") -> Bool {
        let terms = query.split { $0.isWhitespace || $0 == "+" }
        let fields = [title, composer, part, additionalText] + tags
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public var fileName: String { "\(id.uuidString).pdf" }
    /// Defensive display value, even if a transient in-memory edit is invalid.
    public var lastPageNumber: Int {
        guard pageCount > 0 else { return 1 }
        return min(pageCount - 1, max(0, lastPage)) + 1
    }
    public init(id: UUID = UUID(), title: String, pageCount: Int) {
        self.id = id; self.title = title; self.pageCount = pageCount; importedAt = Date()
    }
}

public struct SetlistEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var scoreID: UUID
    public var bookmarkID: UUID?
    public init(id: UUID = UUID(), scoreID: UUID, bookmarkID: UUID? = nil) {
        self.id = id; self.scoreID = scoreID; self.bookmarkID = bookmarkID
    }
}

public struct ScoreSetlist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var entries: [SetlistEntry] = []
    public init(id: UUID = UUID(), title: String) { self.id = id; self.title = title }
}

public struct PenPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var hex: String
    public var width: Double
    public var opacity: Double
    public var highlighter: Bool
    public init(name: String, hex: String, width: Double, opacity: Double = 1, highlighter: Bool = false) {
        id = UUID(); self.name = name; self.hex = hex; self.width = width
        self.opacity = opacity; self.highlighter = highlighter
    }
    public static var defaults: [PenPreset] { [
        .init(name: "Graphite", hex: "252525", width: 2),
        .init(name: "Rehearsal red", hex: "CC4B40", width: 3),
        .init(name: "Highlight", hex: "F3CA45", width: 18, opacity: 0.3, highlighter: true)
    ] }
}

public struct ReaderSettings: Codable, Equatable, Sendable {
    public var preventFingerDrawing = true
    public var pencilAutoAnnotate = true
    public var halfPageTurns = false
    public var continueSetlist = true
    public var keepScreenAwake = true
    public var landscapeSteps = true
    public var presets = PenPreset.defaults
    public init() {}
}

public struct LibraryIndex: Codable, Equatable, Sendable {
    public var version = 2
    public var scores: [Score] = []
    public var setlists: [ScoreSetlist] = []
    public var settings = ReaderSettings()
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, scores, setlists, settings }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try c.decode(Int.self, forKey: .version)
        guard (1...2).contains(sourceVersion) else { throw LibraryError.unsupportedVersion }
        version = 2
        scores = try c.decode([Score].self, forKey: .scores)
        setlists = try c.decode([ScoreSetlist].self, forKey: .setlists)
        settings = try c.decode(ReaderSettings.self, forKey: .settings)
    }
    public var activeScores: [Score] { scores.filter { !$0.isDeleted } }
    public var deletedScores: [Score] { scores.filter(\.isDeleted) }

    /// One semantic boundary for local indexes, saves and portable backups.
    /// Reject damaged data instead of silently changing the user's rehearsal state.
    public func validate() throws {
        guard version == 2 else { throw LibraryError.unsupportedVersion }
        guard Set(scores.map(\.id)).count == scores.count,
              Set(setlists.map(\.id)).count == setlists.count,
              Set(settings.presets.map(\.id)).count == settings.presets.count else { throw LibraryError.corruptIndex }
        for score in scores {
            guard score.purgePendingAt == nil || score.deletedAt != nil else { throw LibraryError.corruptIndex }
            // The page slider converts page positions through Double and back to Int.
            guard score.pageCount > 0, Int(exactly: Double(score.pageCount)) != nil,
                  (0..<score.pageCount).contains(score.lastPage),
                  Set(score.bookmarks.map(\.id)).count == score.bookmarks.count,
                  score.bookmarks.allSatisfy({ $0.isValid(pageCount: score.pageCount) }),
                  score.layouts.allSatisfy({ page, layout in
                      var normalized = layout; normalized.normalize()
                      return (0..<score.pageCount).contains(page) && normalized == layout
                  }),
                  score.viewports.allSatisfy({ page, viewport in
                      var normalized = viewport; normalized.normalize()
                      return (0..<score.pageCount).contains(page) && normalized == viewport
                  }) else { throw LibraryError.corruptIndex }
        }
        for setlist in setlists {
            guard Set(setlist.entries.map(\.id)).count == setlist.entries.count,
                  setlist.entries.allSatisfy({ entry in
                      guard let score = scores.first(where: { $0.id == entry.scoreID }) else { return false }
                      guard let bookmarkID = entry.bookmarkID else { return true }
                      // Older item-to-page edits left inert references. Preserve that known
                      // legacy state; resolve still excludes page bookmarks from reading queues.
                      return score.bookmarks.contains { $0.id == bookmarkID }
                  }) else { throw LibraryError.corruptIndex }
        }
        guard settings.presets.allSatisfy({
            $0.width.isFinite && $0.width > 0 && $0.width <= 100 &&
            $0.opacity.isFinite && (0...1).contains($0.opacity)
        }) else { throw LibraryError.corruptIndex }
    }

    public func resolve(_ entry: SetlistEntry) -> ReadingItem? {
        guard let score = scores.first(where: { $0.id == entry.scoreID && !$0.isDeleted }) else { return nil }
        if let bookmarkID = entry.bookmarkID {
            guard let bookmark = score.bookmarks.first(where: { $0.id == bookmarkID }),
                  bookmark.isItem, bookmark.isValid(pageCount: score.pageCount) else { return nil }
            return ReadingItem(id: entry.id, scoreID: score.id, title: bookmark.title,
                               startPage: bookmark.startPage, endPage: bookmark.endPage!)
        }
        guard score.pageCount > 0 else { return nil }
        return ReadingItem(id: entry.id, scoreID: score.id, title: score.title,
                           startPage: 0, endPage: score.pageCount - 1)
    }

    public mutating func removeScore(_ id: UUID) {
        guard let i = scores.firstIndex(where: { $0.id == id }), scores[i].deletedAt == nil else { return }
        scores[i].deletedAt = Date()
    }
    public mutating func restoreScore(_ id: UUID) {
        guard let i = scores.firstIndex(where: { $0.id == id }), scores[i].purgePendingAt == nil else { return }
        scores[i].deletedAt = nil
    }
    mutating func finishRemovingScore(_ id: UUID) {
        scores.removeAll { $0.id == id }
        for i in setlists.indices { setlists[i].entries.removeAll { $0.scoreID == id } }
    }
    public mutating func removeBookmark(scoreID: UUID, bookmarkID: UUID) {
        guard let i = scores.firstIndex(where: { $0.id == scoreID }) else { return }
        scores[i].bookmarks.removeAll { $0.id == bookmarkID }
        for i in setlists.indices {
            setlists[i].entries.removeAll { $0.scoreID == scoreID && $0.bookmarkID == bookmarkID }
        }
    }
}
