import Foundation

public struct RetainedLibraryFile: Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let bytes: UInt64
}

public struct LibraryStorageUsage: Sendable {
    public var pdfBytes: UInt64 = 0
    public var savedInkBytes: UInt64 = 0
    public var draftBytes: UInt64 = 0
    public var metadataBytes: UInt64 = 0
    /// Subset of score assets; never add this to the total again.
    public var recentlyDeletedBytes: UInt64 = 0
    public var cacheBytes: UInt64 = 0
    public var retainedBytes: UInt64 = 0
    public var otherBytes: UInt64 = 0
    public var scoreBytes: [UUID: UInt64] = [:]
    public var retainedFiles: [RetainedLibraryFile] = []
    public let calculatedAt = Date()
    public var totalBytes: UInt64 { pdfBytes + savedInkBytes + draftBytes + metadataBytes + cacheBytes + retainedBytes + otherBytes }
}

/// Exact ownership by UUID and canonical page number. Unknown files are never cleanup candidates.
enum ScoreAssetOwnership {
    static func owner(_ name: String, directory: String) -> UUID? {
        if directory == "Scores" {
            guard name.hasSuffix(".pdf"), let id = UUID(uuidString: String(name.dropLast(4))),
                  name == "\(id.uuidString).pdf" else { return nil }
            return id
        }
        let suffix = name.hasSuffix(".drawing") ? ".drawing" : directory == "Ink" && name.hasSuffix(".draft-commit") ? ".draft-commit" : ""
        guard !suffix.isEmpty, name.count > 37 + suffix.count,
              let id = UUID(uuidString: String(name.prefix(36))) else { return nil }
        let pageText = String(name.dropFirst(37).dropLast(suffix.count))
        guard let page = Int(pageText), page >= 0, name == "\(id.uuidString)-\(page)\(suffix)" else { return nil }
        return id
    }
    static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LibraryError.unsafeStorage }
    }
    static func regularSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw LibraryError.unsafeStorage }
        return size.uint64Value
    }
}

extension LibraryDisk {
    public var cacheDirectory: URL { root.appendingPathComponent("Cache", isDirectory: true) }

    /// File lengths, not allocated blocks. Call from a background task; no asset contents are read.
    public func storageUsage(index: LibraryIndex) throws -> LibraryStorageUsage {
        try index.validate()
        var result = LibraryStorageUsage()
        let ids = Set(index.scores.map(\.id)), deleted = Set(index.deletedScores.map(\.id))
        for directory in [pdfDirectory, inkDirectory, recoveryDirectory] {
            try ScoreAssetOwnership.requireDirectory(directory)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let bytes = try ScoreAssetOwnership.regularSize(file)
                guard let id = ScoreAssetOwnership.owner(file.lastPathComponent, directory: directory.lastPathComponent), ids.contains(id) else {
                    result.retainedFiles.append(.init(relativePath: directory.lastPathComponent + "/" + file.lastPathComponent, bytes: bytes))
                    result.retainedBytes += bytes; continue
                }
                result.scoreBytes[id, default: 0] += bytes
                if deleted.contains(id) { result.recentlyDeletedBytes += bytes }
                if directory == pdfDirectory { result.pdfBytes += bytes }
                else if directory == recoveryDirectory { result.draftBytes += bytes }
                else if file.pathExtension == "drawing" { result.savedInkBytes += bytes }
                else { result.metadataBytes += bytes }
            }
        }
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try ScoreAssetOwnership.requireDirectory(cacheDirectory)
            // Only flat, app-owned cache files are supported. Redirects and unexpected directories fail closed.
            for file in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
                result.cacheBytes += try ScoreAssetOwnership.regularSize(file)
            }
        }
        result.retainedFiles.sort { $0.relativePath < $1.relativePath }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where !["Scores", "Ink", "Drafts", "Cache"].contains(file.lastPathComponent) {
            result.otherBytes += try Self.storageTreeBytes(file)
        }
        return result
    }

    private static func storageTreeBytes(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeRegular { return try ScoreAssetOwnership.regularSize(url) }
        try ScoreAssetOwnership.requireDirectory(url)
        var total: UInt64 = 0
        for file in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            total += try storageTreeBytes(file)
        }
        return total
    }

    public func clearCache() throws {
        try withExclusiveWrite {
            guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
            try ScoreAssetOwnership.requireDirectory(cacheDirectory)
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            // Validate all candidates before removing any. No user asset directory is a candidate.
            for file in files { _ = try ScoreAssetOwnership.regularSize(file) }
            for file in files { try FileManager.default.removeItem(at: file) }
        }
    }
}
