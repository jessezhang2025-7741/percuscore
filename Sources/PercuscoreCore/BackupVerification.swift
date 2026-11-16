import Foundation
import CryptoKit

enum BackupFileDigest {
    static let maximumArchiveBytes: UInt64 = 2 * 1024 * 1024 * 1024 + 16 * 1024 * 1024 + 48
    static func read(_ url: URL, maximumBytes: UInt64 = maximumArchiveBytes) throws -> (count: UInt64, digest: Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= maximumBytes else { throw BackupError.resourceLimit }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), count: UInt64 = 0
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            guard UInt64(bytes.count) <= maximumBytes - count else { throw BackupError.resourceLimit }
            count += UInt64(bytes.count); hash.update(data: bytes)
        }
        return (count, Data(hash.finalize()))
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// Ignore identity changes, but retain order, scoped references and all rehearsal values.
struct BackupContentSnapshot: Codable, Equatable {
    struct Asset: Codable, Equatable {
        var scoreID: UUID
        var page: Int?
        var kind: String
        var count: UInt64
        var digest: Data
    }
    let index: LibraryIndex
    let assets: [Asset]
    init(index original: LibraryIndex, assets originalAssets: [Asset]) throws {
        try original.validate()
        func id(_ position: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", position + 1))! }
        let scores = Dictionary(uniqueKeysWithValues: original.scores.enumerated().map { ($0.element.id, id($0.offset)) })
        let bookmarks = Dictionary(uniqueKeysWithValues: original.scores.map { score in
            (score.id, Dictionary(uniqueKeysWithValues: score.bookmarks.enumerated().map { ($0.element.id, id($0.offset)) }))
        })
        var normalized = original
        for i in normalized.scores.indices {
            normalized.scores[i].id = id(i)
            for j in normalized.scores[i].bookmarks.indices { normalized.scores[i].bookmarks[j].id = id(j) }
        }
        for i in normalized.setlists.indices {
            normalized.setlists[i].id = id(i)
            for j in normalized.setlists[i].entries.indices {
                let old = original.setlists[i].entries[j]
                normalized.setlists[i].entries[j].id = id(j)
                normalized.setlists[i].entries[j].scoreID = scores[old.scoreID]!
                normalized.setlists[i].entries[j].bookmarkID = old.bookmarkID.flatMap { bookmarks[old.scoreID]?[$0] }
            }
        }
        for i in normalized.settings.presets.indices { normalized.settings.presets[i].id = id(i) }
        index = normalized
        assets = try originalAssets.map { asset in
            guard let scoreID = scores[asset.scoreID] else { throw BackupError.invalid }
            var mapped = asset; mapped.scoreID = scoreID; return mapped
        }.sorted { "\($0.scoreID)-\($0.kind)-\($0.page ?? -1)" < "\($1.scoreID)-\($1.kind)-\($1.page ?? -1)" }
    }
    static func capture(index: LibraryIndex, disk: LibraryDisk) throws -> Self {
        try index.validate()
        let lease = disk.beginBackupSnapshot(); defer { lease.release() }
        var assets: [Asset] = []
        let scores = Dictionary(uniqueKeysWithValues: index.scores.map { ($0.id, $0) })
        for score in index.scores {
            let fingerprint = try BackupFileDigest.read(disk.pdfURL(for: score.id), maximumBytes: 512 * 1024 * 1024)
            assets.append(.init(scoreID: score.id, kind: "pdf", count: fingerprint.count, digest: fingerprint.digest))
        }
        for (kind, directory) in [("ink", disk.inkDirectory), ("draft", disk.recoveryDirectory)] {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "drawing", name.count > 37,
                      let id = UUID(uuidString: String(name.prefix(36))), name.dropFirst(36).first == "-",
                      let page = Int(name.dropFirst(37)), let score = scores[id], (0..<score.pageCount).contains(page),
                      let bytes = try disk.readInk(scoreID: id, page: page, draft: kind == "draft") else { continue }
                assets.append(.init(scoreID: id, page: page, kind: kind, count: UInt64(bytes.count), digest: Data(SHA256.hash(data: bytes))))
            }
        }
        return try Self(index: index, assets: assets)
    }
    var sha256: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return BackupFileDigest.hex(Data(SHA256.hash(data: try encoder.encode(self))))
        }
    }
}

public struct BackupVerification: Codable, Equatable, Sendable {
    public let archiveSHA256: String
    public let contentSHA256: String
    public let verifiedAt: Date
    public let scoreCount: Int
    public let setlistCount: Int
    public let pdfCount: Int
    public let savedInkCount: Int
    public let draftCount: Int
    public var deletedScoreCount: Int? = nil
    public var deletedAssetBytes: UInt64? = nil
}

extension LibraryBackup {
    public static func fileSHA256(_ url: URL) throws -> String { BackupFileDigest.hex(try BackupFileDigest.read(url).digest) }
    /// A new directory is mandatory. Existing libraries and the original file remain untouched.
    public static func verify(from archive: URL, at destination: URL) throws -> BackupVerification {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let identity = try fileSHA256(archive)
        let expected = try manifestSnapshot(from: archive)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let disk = try LibraryDisk(root: destination)
        _ = try restore(from: archive, disk: disk, current: LibraryIndex())
        let reopened = try LibraryDisk(root: destination)
        let actual = try BackupContentSnapshot.capture(index: reopened.load(), disk: reopened)
        guard actual == expected, try fileSHA256(archive) == identity else { throw BackupError.verificationMismatch }
        let deletedIDs = Set(actual.index.deletedScores.map(\.id))
        let result = BackupVerification(archiveSHA256: identity, contentSHA256: try actual.sha256, verifiedAt: Date(),
            scoreCount: actual.index.scores.count, setlistCount: actual.index.setlists.count,
            pdfCount: actual.assets.filter { $0.kind == "pdf" }.count,
            savedInkCount: actual.assets.filter { $0.kind == "ink" }.count,
            draftCount: actual.assets.filter { $0.kind == "draft" }.count,
            deletedScoreCount: deletedIDs.count,
            deletedAssetBytes: actual.assets.filter { deletedIDs.contains($0.scoreID) }.reduce(0) { $0 + $1.count })
        succeeded = true; return result
    }
}
