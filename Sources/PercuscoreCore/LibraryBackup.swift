import Foundation
import CryptoKit
import PDFKit
import PencilKit

public enum BackupError: LocalizedError {
    case invalid, unsupported, missingAsset, resourceLimit, verificationMismatch
    case invalidContent(score: String, asset: String)
    public var errorDescription: String? {
        switch self {
        case .invalid: return "This backup is incomplete or damaged. Your current library has not been replaced."
        case .unsupported: return "This backup needs a newer version of Percuscore."
        case .missingAsset: return "A score PDF is missing. Restore the missing PDF before creating a backup."
        case .verificationMismatch: return "Restored content does not match this backup. The original file and your library have been preserved."
        case .resourceLimit: return "This backup exceeds the restore safety limits. Keep the original backup for recovery; your current library has not been changed."
        case .invalidContent(let score, let asset): return "The \(asset) in ‘\(score)’ cannot be read safely. Keep the original backup for recovery; your current library has not been changed."
        }
    }
}

/// Single-file format: magic, big-endian manifest length, SHA256(manifest), JSON manifest, streamed assets.
/// No archive path is ever used as a destination. Assets are addressed by validated UUID/page/type.
public enum LibraryBackup {
    private static let magic = Data("PERCUB01".utf8)
    private static let chunkSize = 1_048_576
    private static let maximumPDFBytes: UInt64 = 512 * 1024 * 1024
    private static let maximumTotalBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let maximumAssets = 50_000
    private static let maximumPagesPerPDF = 5_000
    private static let maximumTotalPages = 20_000
    private static let maximumPointsPerDrawing = 250_000
    private static let maximumTotalPoints = 2_000_000
    private struct Asset: Codable {
        var scoreID: UUID
        var page: Int?
        var kind: String
        var count: UInt64
        var digest: Data
        var key: String { "\(scoreID)-\(kind)-\(page ?? -1)" }
    }
    private struct Manifest: Codable {
        var version = 2
        var createdAt = Date()
        var index: LibraryIndex
        var assets: [Asset]
    }

    public static func export(index: LibraryIndex, disk: LibraryDisk, to destination: URL) throws {
        let lease = disk.beginBackupSnapshot(); defer { lease.release() }
        try validate(index)
        for score in index.scores { try PurgeTransaction.requireWritable(score.id, disk: disk) }
        try validatePageBudget(index)
        var assets: [Asset] = []
        var totalAssetBytes: UInt64 = 0
        let draftStage = destination.deletingLastPathComponent().appendingPathComponent(".draft-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: draftStage) }
        var draftSources: [String: URL] = [:]
        for score in index.scores {
            let pdf = disk.pdfURL(for: score.id)
            guard FileManager.default.fileExists(atPath: pdf.path) else { throw BackupError.missingAsset }
            let fingerprint = try hashFile(pdf, maximumBytes: maximumPDFBytes)
            try appendAsset(Asset(scoreID: score.id, kind: "pdf", count: fingerprint.0, digest: fingerprint.1), to: &assets, total: &totalAssetBytes)
        }
        let scores = Dictionary(uniqueKeysWithValues: index.scores.map { ($0.id, $0) })
        for (kind, directory) in [("ink", disk.inkDirectory), ("draft", disk.recoveryDirectory)] {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "drawing", name.count > 37,
                      let id = UUID(uuidString: String(name.prefix(36))),
                      name.dropFirst(36).first == "-",
                      let page = Int(name.dropFirst(37)), let score = scores[id],
                      (0..<score.pageCount).contains(page) else { continue }
                var source = file
                if kind == "draft" {
                    // Omit retired copies and keep portable draft assets in the legacy raw format.
                    guard let data = try disk.readInk(scoreID: id, page: page, draft: true) else { continue }
                    try FileManager.default.createDirectory(at: draftStage, withIntermediateDirectories: true)
                    source = draftStage.appendingPathComponent(file.lastPathComponent)
                    try data.write(to: source, options: .atomic)
                }
                let fingerprint = try hashFile(source, maximumBytes: UInt64(LibraryDisk.maximumDrawingBytes))
                let asset = Asset(scoreID: id, page: page, kind: kind, count: fingerprint.0, digest: fingerprint.1)
                try appendAsset(asset, to: &assets, total: &totalAssetBytes)
                if kind == "draft" { draftSources[asset.key] = source }
            }
        }
        try validateAssetBudget(assets)
        let manifest = Manifest(index: index, assets: assets)
        let header = try JSONEncoder().encode(manifest)
        guard header.count <= 16 * chunkSize else { throw BackupError.invalid }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: magic)
        var length = UInt64(header.count).bigEndian
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: Data(SHA256.hash(data: header)))
        try output.write(contentsOf: header)
        for asset in assets {
            let input = try FileHandle(forReadingFrom: draftSources[asset.key] ?? assetURL(asset, disk: disk))
            defer { try? input.close() }
            try transfer(input, output, asset: asset)
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.invalid }
        }
        try output.synchronize()
        try output.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public static func restore(from archive: URL, disk: LibraryDisk, current: LibraryIndex) throws -> LibraryIndex {
        try disk.withExclusiveWrite { try restoreExclusively(from: archive, disk: disk, current: current) }
    }
    private static func restoreExclusively(from archive: URL, disk: LibraryDisk, current: LibraryIndex) throws -> LibraryIndex {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        guard try read(input, count: 8) == magic else { throw BackupError.invalid }
        let length = try read(input, count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= 16 * chunkSize else { throw BackupError.invalid }
        let headerHash = try read(input, count: 32)
        let header = try read(input, count: Int(length))
        guard Data(SHA256.hash(data: header)) == headerHash else { throw BackupError.invalid }
        let manifest = try JSONDecoder().decode(Manifest.self, from: header)
        guard (1...2).contains(manifest.version) else { throw BackupError.unsupported }
        try validate(manifest.index); try validate(current)
        try validatePageBudget(manifest.index)
        try validateAssetBudget(manifest.assets)
        let scoreMap = Dictionary(uniqueKeysWithValues: manifest.index.scores.map { ($0.id, $0) })
        var keys = Set<String>()
        var pdfIDs = Set<UUID>()
        for asset in manifest.assets {
            guard let score = scoreMap[asset.scoreID], asset.digest.count == 32,
                  keys.insert(asset.key).inserted else { throw BackupError.invalid }
            if asset.kind == "pdf" {
                guard asset.page == nil, asset.count > 0 else { throw BackupError.invalid }
                pdfIDs.insert(asset.scoreID)
            } else {
                guard ["ink", "draft"].contains(asset.kind),
                      let page = asset.page, (0..<score.pageCount).contains(page) else { throw BackupError.invalid }
            }
        }
        guard pdfIDs == Set(scoreMap.keys) else { throw BackupError.invalid }
        let stageRoot = disk.root.appendingPathComponent(".restore-\(UUID())")
        var journalPublished = false
        defer { if !journalPublished { try? FileManager.default.removeItem(at: stageRoot) } }
        let staged = try LibraryDisk(root: stageRoot)
        try RestoreTransaction.beginStaging(at: stageRoot, disk: disk)
        for asset in manifest.assets {
            let url = assetURL(asset, disk: staged)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            try transfer(input, output, asset: asset)
            try output.synchronize()
            try output.close()
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.invalid }

        // Decode all content in isolation before a single staged asset is installed.
        try validateContent(index: manifest.index, assets: manifest.assets, disk: staged)

        var restored = manifest.index
        let ids = Dictionary(uniqueKeysWithValues: restored.scores.map { ($0.id, UUID()) })
        for i in restored.scores.indices { restored.scores[i].id = ids[restored.scores[i].id]! }
        for i in restored.setlists.indices {
            restored.setlists[i].id = UUID()
            for j in restored.setlists[i].entries.indices {
                restored.setlists[i].entries[j].id = UUID()
                restored.setlists[i].entries[j].scoreID = ids[restored.setlists[i].entries[j].scoreID]!
            }
        }
        var merged = current
        if current.scores.isEmpty && current.setlists.isEmpty { merged.settings = restored.settings }
        merged.scores += restored.scores; merged.setlists += restored.setlists
        _ = try RestoreTransaction.prepare(at: stageRoot, disk: disk, scoreIDs: Array(ids.values), assets: manifest.assets.map {
            RestoreTransaction.Asset(scoreID: ids[$0.scoreID]!, page: $0.page, kind: $0.kind, count: $0.count, digest: $0.digest)
        })
        journalPublished = true
        do {
            for asset in manifest.assets {
                var renamed = asset; renamed.scoreID = ids[asset.scoreID]!
                let destination = assetURL(renamed, disk: disk)
                try FileManager.default.moveItem(at: assetURL(asset, disk: staged), to: destination)
            }
            // Commit the index only after every asset has been validated and installed.
            try disk.save(merged)
        } catch {
            // Read the atomic index to decide whether installation committed. If
            // cleanup fails, retain the journal for a later startup instead of guessing.
            _ = try? disk.load()
            throw error
        }
        _ = RestoreTransaction.recover(disk: disk, current: merged, uncertainIndex: false)
        return merged
    }

    static func manifestSnapshot(from archive: URL) throws -> BackupContentSnapshot {
        let input = try FileHandle(forReadingFrom: archive); defer { try? input.close() }
        guard try read(input, count: 8) == magic else { throw BackupError.invalid }
        let length = try read(input, count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= 16 * chunkSize else { throw BackupError.invalid }
        let hash = try read(input, count: 32), bytes = try read(input, count: Int(length))
        guard Data(SHA256.hash(data: bytes)) == hash else { throw BackupError.invalid }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard (1...2).contains(manifest.version) else { throw BackupError.unsupported }
        try validate(manifest.index); try validatePageBudget(manifest.index); try validateAssetBudget(manifest.assets)
        return try BackupContentSnapshot(index: manifest.index, assets: manifest.assets.map {
            .init(scoreID: $0.scoreID, page: $0.page, kind: $0.kind, count: $0.count, digest: $0.digest)
        })
    }

    public static func deletedSummary(from archive: URL) throws -> (count: Int, bytes: UInt64) {
        let snapshot = try manifestSnapshot(from: archive)
        let ids = Set(snapshot.index.deletedScores.map(\.id))
        return (ids.count, snapshot.assets.filter { ids.contains($0.scoreID) }.reduce(0) { $0 + $1.count })
    }

    private static func validatePageBudget(_ index: LibraryIndex) throws {
        var pages = 0
        for score in index.scores {
            guard score.pageCount <= maximumPagesPerPDF, score.pageCount <= maximumTotalPages - pages else {
                throw BackupError.resourceLimit
            }
            pages += score.pageCount
        }
    }

    private static func appendAsset(_ asset: Asset, to assets: inout [Asset], total: inout UInt64) throws {
        guard assets.count < maximumAssets, asset.count <= maximumTotalBytes - total else { throw BackupError.resourceLimit }
        total += asset.count; assets.append(asset)
    }

    private static func validateAssetBudget(_ assets: [Asset]) throws {
        guard assets.count <= maximumAssets else { throw BackupError.resourceLimit }
        var total: UInt64 = 0
        for asset in assets {
            let limit = asset.kind == "pdf" ? maximumPDFBytes : UInt64(LibraryDisk.maximumDrawingBytes)
            guard asset.count <= limit, asset.count <= maximumTotalBytes - total else { throw BackupError.resourceLimit }
            total += asset.count
        }
    }

    private static func validateContent(index: LibraryIndex, assets: [Asset], disk: LibraryDisk) throws {
        for score in index.scores {
            try autoreleasepool {
                guard let document = PDFDocument(url: disk.pdfURL(for: score.id)), !document.isLocked,
                      document.pageCount == score.pageCount else {
                    throw BackupError.invalidContent(score: score.title, asset: "PDF")
                }
                for number in 0..<document.pageCount {
                    guard let page = document.page(at: number), let reference = page.pageRef else {
                        throw BackupError.invalidContent(score: score.title, asset: "PDF")
                    }
                    let box = reference.getBoxRect(.mediaBox)
                    let values = [box.origin.x, box.origin.y, box.width, box.height]
                    guard values.allSatisfy({ $0.isFinite && abs($0) <= 14_400 }),
                          box.width >= 1, box.height >= 1,
                          box.width / box.height <= 1_000, box.height / box.width <= 1_000,
                          page.rotation % 90 == 0 else {
                        throw BackupError.invalidContent(score: score.title, asset: "PDF page \(number + 1)")
                    }
                }
            }
        }
        let scores = Dictionary(uniqueKeysWithValues: index.scores.map { ($0.id, $0) })
        var totalPoints = 0
        for asset in assets where asset.kind != "pdf" {
            try autoreleasepool {
                let data = try LibraryDisk.readBounded(assetURL(asset, disk: disk), maximumBytes: LibraryDisk.maximumDrawingBytes)
                let drawing: PKDrawing
                do { drawing = try PKDrawing(data: data) }
                catch { throw BackupError.invalidContent(score: scores[asset.scoreID]!.title, asset: "markings on page \(asset.page! + 1)") }
                guard drawing.strokes.count <= 10_000 else { throw BackupError.resourceLimit }
                var points = 0
                for stroke in drawing.strokes {
                    guard stroke.path.count <= maximumPointsPerDrawing - points else { throw BackupError.resourceLimit }
                    points += stroke.path.count
                    let box = stroke.renderBounds
                    guard [box.origin.x, box.origin.y, box.width, box.height].allSatisfy({ $0.isFinite && abs($0) <= 2_000_000 }) else {
                        throw BackupError.invalidContent(score: scores[asset.scoreID]!.title, asset: "markings on page \(asset.page! + 1)")
                    }
                }
                guard points <= maximumTotalPoints - totalPoints else { throw BackupError.resourceLimit }
                totalPoints += points
            }
        }
    }

    private static func assetURL(_ asset: Asset, disk: LibraryDisk) -> URL {
        if asset.kind == "pdf" { return disk.pdfURL(for: asset.scoreID) }
        let directory = asset.kind == "draft" ? disk.recoveryDirectory : disk.inkDirectory
        return directory.appendingPathComponent("\(asset.scoreID.uuidString)-\(asset.page!).drawing")
    }
    private static func read(_ input: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try input.read(upToCount: count - result.count), !part.isEmpty else { throw BackupError.invalid }
            result.append(part)
        }
        return result
    }
    private static func hashFile(_ url: URL, maximumBytes: UInt64) throws -> (UInt64, Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= maximumBytes else { throw BackupError.resourceLimit }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256(); var count: UInt64 = 0
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty {
            guard UInt64(data.count) <= maximumBytes - count else { throw BackupError.resourceLimit }
            hash.update(data: data); count += UInt64(data.count)
        }
        return (count, Data(hash.finalize()))
    }
    private static func transfer(_ input: FileHandle, _ output: FileHandle, asset: Asset) throws {
        var remaining = asset.count; var hash = SHA256()
        while remaining > 0 {
            let data = try read(input, count: Int(min(UInt64(chunkSize), remaining)))
            hash.update(data: data); try output.write(contentsOf: data); remaining -= UInt64(data.count)
        }
        guard Data(hash.finalize()) == asset.digest else { throw BackupError.invalid }
    }
    private static func validate(_ index: LibraryIndex) throws {
        do { try index.validate() }
        catch LibraryError.unsupportedVersion { throw BackupError.unsupported }
        catch { throw BackupError.invalid }
        guard index.scores.allSatisfy({ $0.purgePendingAt == nil }) else { throw LibraryError.cleanupPending }
    }
}
