import Foundation

public struct ReaderDiagnosticEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case modeChanged, pageLoaded, pageFailed, saveDraft, saveAnnotation, saveCrop, saveProgress, draftCleanup
        case focusUpdate, strokeBegan, strokeChanged, strokeEnded, lifecycle
    }
    public enum State: String, Codable, Sendable {
        case reading, annotating, cropping, started, succeeded, failed, detached, active, inactive, background
    }
    public let timestamp: Date
    public let kind: Kind
    public let state: State
    public let page: Int?
    public let item: Int?
    public var durationMS: Double?
    public var build: AcceptanceBuild?
    public var processID: UUID?
    public init(kind: Kind, state: State, page: Int? = nil, item: Int? = nil, durationMS: Double? = nil) {
        timestamp = Date(); self.kind = kind; self.state = state; self.page = page; self.item = item; self.durationMS = durationMS
    }
}

/// Metadata only; caller input can never supply text, paths, PDF bytes or PKDrawing.
/// A private queue batches atomic writes so input handling never waits for disk.
public final class BoundedDiagnosticLog: @unchecked Sendable {
    private let url: URL
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let queue = DispatchQueue(label: "com.percuscore.diagnostics", qos: .utility)
    private var events: [ReaderDiagnosticEvent] = []
    private var scheduled = false
    public init(url: URL, maximumBytes: Int = 256 * 1024, maximumEntries: Int = 512) {
        self.url = url; self.maximumBytes = max(512, min(256 * 1024, maximumBytes))
        self.maximumEntries = max(1, min(512, maximumEntries))
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= self.maximumBytes,
           let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            events = Array(((try? decoder.decode([ReaderDiagnosticEvent].self, from: data)) ?? []).suffix(self.maximumEntries))
        }
    }
    public func record(_ event: ReaderDiagnosticEvent) {
        var sanitized = event
        if let value = sanitized.durationMS, !value.isFinite || value < 0 { sanitized.durationMS = nil }
        let accepted = sanitized
        queue.async {
            self.events.append(accepted)
            if self.events.count > self.maximumEntries { self.events.removeFirst(self.events.count - self.maximumEntries) }
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.scheduled = false
                try? self.write()
            }
        }
    }
    private func write() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(events)
        while data.count > maximumBytes, !events.isEmpty {
            events.removeFirst(); data = try encoder.encode(events)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    public func flush() throws { try queue.sync { try write() } }
    public func snapshot() throws -> [ReaderDiagnosticEvent] { queue.sync { events } }
    public func clear() throws { try queue.sync { events = []; try write() } }
}
