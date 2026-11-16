import Foundation
import CryptoKit

public enum LibraryError: LocalizedError {
    case invalidPDF, invalidBookmark, corruptIndex, unsupportedVersion, missingFile, inkTooLarge, backupInProgress, cleanupPending, unsafeStorage
    public var errorDescription: String? {
        switch self {
        case .invalidPDF: return "This file is not a readable PDF, is password protected, or has no pages."
        case .invalidBookmark: return "Check the bookmark title and page range."
        case .corruptIndex: return "The library index could not be read. Your PDF and ink files have been preserved."
        case .unsupportedVersion: return "This library was created by a newer version of Percuscore. Please update the app."
        case .missingFile: return "The PDF could not be found in the library."
        case .inkTooLarge: return "This markings file exceeds the safety limit. The original file has been preserved."
        case .backupInProgress: return "A backup snapshot is being prepared. Your previous data is unchanged; retry saving after preparation finishes."
        case .cleanupPending: return "Permanent deletion is pending or completed for this score. Retry pending cleanup from Recently Deleted; the score cannot be restored or edited."
        case .unsafeStorage: return "Storage could not be checked safely. The files have been preserved; check the library folder and try again."
        }
    }
}

/// The caller serializes access. Every replacement is atomic; a previous valid index is retained.
public final class LibraryDisk {
    public static let maximumDrawingBytes = 16 * 1024 * 1024
    private static let maximumStoredDrawingBytes = maximumDrawingBytes + 64 * 1024
    public let root: URL
    public let pdfDirectory: URL
    public let inkDirectory: URL
    public let recoveryDirectory: URL
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private var backupURL: URL { root.appendingPathComponent("library.backup.json") }
    public private(set) var recoveredFromBackup = false
    public private(set) var restoreRecoveryWarning: String?
    private let fm = FileManager.default
    private let access: LibraryRootAccess

    public init(root: URL) throws {
        self.root = root
        access = LibraryRootAccess.shared(root)
        pdfDirectory = root.appendingPathComponent("Scores", isDirectory: true)
        inkDirectory = root.appendingPathComponent("Ink", isDirectory: true)
        recoveryDirectory = root.appendingPathComponent("Drafts", isDirectory: true)
        for dir in [root, pdfDirectory, inkDirectory, recoveryDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
    public func beginBackupSnapshot() -> LibrarySnapshotLease { LibrarySnapshotLease(access) }
    func withExclusiveWrite<T>(_ body: () throws -> T) throws -> T { try access.write(body) }
    private func finishLoad(_ original: LibraryIndex) throws -> LibraryIndex {
        let index = try PurgeTransaction.reconcile(original, disk: self)
        guard access.readers == 0 else { return index }
        restoreRecoveryWarning = RestoreTransaction.recover(disk: self, current: index, uncertainIndex: recoveredFromBackup)
        return index
    }
    private func decode(_ url: URL) throws -> LibraryIndex {
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: url))
        try index.validate()
        return index
    }
    public func load() throws -> LibraryIndex {
        access.lock.lock(); defer { access.lock.unlock() }
        recoveredFromBackup = false
        guard fm.fileExists(atPath: indexURL.path) else {
            if fm.fileExists(atPath: backupURL.path) {
                do {
                    let backup = try decode(backupURL)
                    recoveredFromBackup = true
                    return try finishLoad(backup)
                } catch LibraryError.unsupportedVersion { throw LibraryError.unsupportedVersion }
                catch { throw LibraryError.corruptIndex }
            }
            return try finishLoad(LibraryIndex())
        }
        do { return try finishLoad(try decode(indexURL)) }
        catch LibraryError.unsupportedVersion { throw LibraryError.unsupportedVersion }
        catch {
            let backup: LibraryIndex
            do { backup = try decode(backupURL) }
            catch LibraryError.unsupportedVersion { throw LibraryError.unsupportedVersion }
            catch { throw LibraryError.corruptIndex }
            // Keep evidence instead of overwriting the corrupted original with an empty library.
            let preserved = root.appendingPathComponent("library-damaged-\(UUID().uuidString).json")
            try fm.copyItem(at: indexURL, to: preserved)
            recoveredFromBackup = true
            return try finishLoad(backup)
        }
    }
    public func save(_ index: LibraryIndex) throws {
        try access.write { try saveUnblocked(index) }
    }
    func savePurgeResult(_ index: LibraryIndex, scoreID: UUID) throws {
        try access.write {
            guard !index.scores.contains(where: { $0.id == scoreID }),
                  try PurgeTransaction.assets(scoreID, disk: self).isEmpty else { throw LibraryError.unsafeStorage }
            try saveUnblocked(index, finishingPurge: scoreID)
        }
    }
    private func saveUnblocked(_ index: LibraryIndex, finishingPurge: UUID? = nil) throws {
        // Validate before encoding or touching either on-disk copy.
        try index.validate()
        try PurgeTransaction.validateSave(index, disk: self, finishing: finishingPurge)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        if fm.fileExists(atPath: indexURL.path), (try? decode(indexURL)) != nil {
            try Data(contentsOf: indexURL).write(to: backupURL, options: .atomic)
        }
        try data.write(to: indexURL, options: .atomic)
    }
    public func pdfURL(for scoreID: UUID) -> URL {
        pdfDirectory.appendingPathComponent("\(scoreID.uuidString).pdf")
    }
    public func copyPDF(from source: URL, scoreID: UUID) throws {
        try access.write {
            try PurgeTransaction.requireWritable(scoreID, disk: self)
            try fm.copyItem(at: source, to: pdfURL(for: scoreID))
        }
    }
    public func inkURL(_ scoreID: UUID, page: Int, draft: Bool = false) -> URL {
        (draft ? recoveryDirectory : inkDirectory).appendingPathComponent("\(scoreID.uuidString)-\(page).drawing")
    }
    public func readInk(scoreID: UUID, page: Int, draft: Bool = false) throws -> Data? {
        let url = inkURL(scoreID, page: page, draft: draft)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let bytes = try Self.readBounded(url, maximumBytes: draft ? Self.maximumStoredDrawingBytes : Self.maximumDrawingBytes)
        guard draft else { return bytes }
        let snapshot = try draftSnapshot(bytes)
        guard snapshot.data.count <= Self.maximumDrawingBytes else { throw LibraryError.inkTooLarge }
        return try isRetired(snapshot.identity, scoreID: scoreID, page: page) ? nil : snapshot.data
    }
    static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(maximumBytes) else {
            throw LibraryError.inkTooLarge
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var result = Data()
        while let part = try input.read(upToCount: min(1_048_576, maximumBytes + 1 - result.count)), !part.isEmpty {
            guard part.count <= maximumBytes - result.count else { throw LibraryError.inkTooLarge }
            result.append(part)
        }
        return result
    }

    public func writeInk(_ data: Data, scoreID: UUID, page: Int, draft: Bool = false) throws {
        try access.write { try writeInkUnblocked(data, scoreID: scoreID, page: page, draft: draft) }
    }
    private func writeInkUnblocked(_ data: Data, scoreID: UUID, page: Int, draft: Bool) throws {
        try PurgeTransaction.requireWritable(scoreID, disk: self)
        guard data.count <= Self.maximumDrawingBytes else { throw LibraryError.inkTooLarge }
        var bytes = data
        if draft {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            bytes = Self.draftMagic + (try encoder.encode(DraftRecord(generation: UUID(), data: data)))
        }
        try bytes.write(to: inkURL(scoreID, page: page, draft: draft), options: .atomic)
    }

    /// The marker is durable before the committed drawing is atomically replaced.
    /// A failed drawing write cannot retire a draft unless its intended bytes are already committed.
    public func commitInk(_ data: Data, scoreID: UUID, page: Int) throws {
        try access.write {
            try prepareInkCommit(data, scoreID: scoreID, page: page)
            try writeInk(data, scoreID: scoreID, page: page)
        }
    }

    func prepareInkCommit(_ data: Data, scoreID: UUID, page: Int) throws {
        try access.write { try prepareInkCommitUnblocked(data, scoreID: scoreID, page: page) }
    }
    private func prepareInkCommitUnblocked(_ data: Data, scoreID: UUID, page: Int) throws {
        try PurgeTransaction.requireWritable(scoreID, disk: self)
        guard data.count <= Self.maximumDrawingBytes else { throw LibraryError.inkTooLarge }
        let draftURL = inkURL(scoreID, page: page, draft: true)
        guard fm.fileExists(atPath: draftURL.path) else { return }
        let identity = try draftSnapshot(Self.readBounded(draftURL, maximumBytes: Self.maximumStoredDrawingBytes)).identity
        let committed = try readInk(scoreID: scoreID, page: page).map { Data(SHA256.hash(data: $0)) }
        // Retain the last completed retirement while preparing a subsequent commit.
        // A crash/failure before that next replacement must not resurrect an older draft.
        let previous = try retirements(scoreID: scoreID, page: page).first {
            $0.identity == identity && $0.committedDigest == committed
        }
        var records = previous.map { [$0] } ?? []
        let next = Retirement(identity: identity, committedDigest: Data(SHA256.hash(data: data)))
        if !records.contains(next) { records.append(next) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(CommitRecord(records: records)).write(to: commitURL(scoreID, page: page), options: .atomic)
    }

    /// Cleanup never removes a later, genuine draft. Returns whether an obsolete copy was removed.
    @discardableResult
    public func cleanupCommittedDraft(scoreID: UUID, page: Int) throws -> Bool {
        try access.write { try cleanupCommittedDraftUnblocked(scoreID: scoreID, page: page) }
    }
    private func cleanupCommittedDraftUnblocked(scoreID: UUID, page: Int) throws -> Bool {
        let url = inkURL(scoreID, page: page, draft: true)
        guard fm.fileExists(atPath: url.path) else { return false }
        let identity = try draftSnapshot(Self.readBounded(url, maximumBytes: Self.maximumStoredDrawingBytes)).identity
        guard try isRetired(identity, scoreID: scoreID, page: page) else { return false }
        try fm.removeItem(at: url)
        // Leftover metadata is inert once the identified draft is gone.
        try? fm.removeItem(at: commitURL(scoreID, page: page))
        return true
    }
    public func discardDraft(scoreID: UUID, page: Int) throws {
        try access.write { try discardDraftUnblocked(scoreID: scoreID, page: page) }
    }
    private func discardDraftUnblocked(scoreID: UUID, page: Int) throws {
        let url = inkURL(scoreID, page: page, draft: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try? fm.removeItem(at: commitURL(scoreID, page: page))
    }

    private static let draftMagic = Data("PERCDR01".utf8)
    private struct DraftRecord: Codable {
        var version = 1
        var generation: UUID
        var data: Data
    }
    private struct DraftIdentity: Codable, Equatable {
        var generation: UUID?
        var digest: Data
    }
    private struct Retirement: Codable, Equatable {
        var identity: DraftIdentity
        var committedDigest: Data
    }
    private struct CommitRecord: Codable {
        var version = 1
        var records: [Retirement]
    }
    private func commitURL(_ scoreID: UUID, page: Int) -> URL {
        inkDirectory.appendingPathComponent("\(scoreID.uuidString)-\(page).draft-commit")
    }
    private func draftSnapshot(_ bytes: Data) throws -> (data: Data, identity: DraftIdentity) {
        let data: Data, generation: UUID?
        if bytes.starts(with: Self.draftMagic) {
            let record = try PropertyListDecoder().decode(DraftRecord.self, from: bytes.dropFirst(Self.draftMagic.count))
            guard record.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            data = record.data; generation = record.generation
        } else { data = bytes; generation = nil } // Raw legacy PKDrawing files remain readable.
        return (data, DraftIdentity(generation: generation, digest: Data(SHA256.hash(data: data))))
    }
    private func retirements(scoreID: UUID, page: Int) throws -> [Retirement] {
        let url = commitURL(scoreID, page: page)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let record = try PropertyListDecoder().decode(CommitRecord.self, from: Self.readBounded(url, maximumBytes: 64 * 1024))
        guard record.version == 1, (1...2).contains(record.records.count),
              record.records.allSatisfy({ $0.identity.digest.count == 32 && $0.committedDigest.count == 32 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record.records
    }
    private func isRetired(_ identity: DraftIdentity, scoreID: UUID, page: Int) throws -> Bool {
        let candidates = try retirements(scoreID: scoreID, page: page).filter { $0.identity == identity }
        guard !candidates.isEmpty, let committed = try readInk(scoreID: scoreID, page: page) else { return false }
        let digest = Data(SHA256.hash(data: committed))
        return candidates.contains { $0.committedDigest == digest }
    }

    // This device's export history is separate from the portable library snapshot.
    private var backupExportURL: URL { root.appendingPathComponent("backup-export.json") }
    public func lastBackupExportDate() throws -> Date? {
        guard fm.fileExists(atPath: backupExportURL.path) else { return nil }
        return try JSONDecoder().decode(Date.self, from: Data(contentsOf: backupExportURL))
    }
    public func recordBackupExport(at date: Date) throws {
        try access.write { try JSONEncoder().encode(date).write(to: backupExportURL, options: .atomic) }
    }
}
