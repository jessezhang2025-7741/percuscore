import Foundation

/// An intent survives process termination. Only typed UUID/page destinations exist.
struct RestoreTransaction {
    struct Asset: Codable {
        let scoreID: UUID
        let page: Int?
        let kind: String
        let count: UInt64
        let digest: Data
        func url(_ disk: LibraryDisk) -> URL {
            kind == "pdf" ? disk.pdfURL(for: scoreID) : disk.inkURL(scoreID, page: page!, draft: kind == "draft")
        }
    }
    private struct Record: Codable {
        var format = "percuscore-restore-transaction"
        var version = 1
        let stageID: UUID
        let phase: String
        let scoreIDs: [UUID]
        let assets: [Asset]
    }
    let journalURL: URL
    private static func stageID(_ stage: URL, disk: LibraryDisk) throws -> UUID {
        let name = stage.lastPathComponent
        guard stage.deletingLastPathComponent().standardizedFileURL.path == disk.root.standardizedFileURL.path,
              name.hasPrefix(".restore-"), let id = UUID(uuidString: String(name.dropFirst(9))) else { throw BackupError.invalid }
        return id
    }
    static func beginStaging(at stage: URL, disk: LibraryDisk) throws {
        _ = try write(at: stage, disk: disk, phase: "staging", scoreIDs: [], assets: [])
    }
    static func prepare(at stage: URL, disk: LibraryDisk, scoreIDs: [UUID], assets: [Asset]) throws -> Self {
        try write(at: stage, disk: disk, phase: "prepared", scoreIDs: scoreIDs, assets: assets)
    }
    private static func write(at stage: URL, disk: LibraryDisk, phase: String, scoreIDs: [UUID], assets: [Asset]) throws -> Self {
        let record = Record(stageID: try stageID(stage, disk: disk), phase: phase, scoreIDs: scoreIDs, assets: assets)
        try validate(record)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let url = stage.appendingPathComponent("transaction.json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
        return Self(journalURL: url)
    }
    private static func validate(_ record: Record) throws {
        let ids = Set(record.scoreIDs)
        guard record.format == "percuscore-restore-transaction", record.version == 1,
              ["staging", "prepared"].contains(record.phase), ids.count == record.scoreIDs.count,
              ids.count <= 20_000, record.assets.count <= 50_000,
              record.phase != "staging" || (ids.isEmpty && record.assets.isEmpty),
              Set(record.assets.map { "\($0.scoreID)-\($0.kind)-\($0.page ?? -1)" }).count == record.assets.count,
              record.assets.reduce(UInt64(0), { $0 + min($1.count, 2 * 1024 * 1024 * 1024 + 1) }) <= 2 * 1024 * 1024 * 1024,
              record.assets.allSatisfy({ asset in
                  ids.contains(asset.scoreID) && asset.digest.count == 32 &&
                  (asset.kind == "pdf" ? asset.page == nil && asset.count > 0 && asset.count <= 512 * 1024 * 1024 :
                    ["ink", "draft"].contains(asset.kind) && asset.page.map { (0..<5_000).contains($0) } == true && asset.count <= LibraryDisk.maximumDrawingBytes)
              }), Set(record.assets.filter { $0.kind == "pdf" }.map(\.scoreID)) == ids else { throw BackupError.invalid }
    }
    /// Failure to clean optional artifacts must never make an intact library unusable.
    static func recover(disk: LibraryDisk, current: LibraryIndex, uncertainIndex: Bool) -> String? {
        let fm = FileManager.default
        var warnings = 0
        do {
            for stage in try fm.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) where stage.lastPathComponent.hasPrefix(".restore-") {
                do {
                    let id = try stageID(stage, disk: disk)
                    let values = try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { throw BackupError.invalid }
                    let record = try JSONDecoder().decode(Record.self, from: LibraryDisk.readBounded(stage.appendingPathComponent("transaction.json"), maximumBytes: 16 * 1024 * 1024))
                    try validate(record)
                    guard record.stageID == id else { throw BackupError.invalid }
                    if record.phase == "prepared" {
                        guard !uncertainIndex else { throw BackupError.invalid }
                        let present = Set(current.scores.map(\.id)).intersection(record.scoreIDs)
                        guard present.isEmpty || present.count == record.scoreIDs.count else { throw BackupError.invalid }
                        if present.isEmpty {
                            // Validate every candidate first; preserve mismatched or redirected files.
                            let installed = record.assets.filter { fm.fileExists(atPath: $0.url(disk).path) }
                            for asset in installed {
                                let url = asset.url(disk)
                                let directory = asset.kind == "pdf" ? "Scores" : asset.kind == "draft" ? "Drafts" : "Ink"
                                let expected = disk.root.resolvingSymlinksInPath().appendingPathComponent(directory).appendingPathComponent(url.lastPathComponent)
                                guard url.resolvingSymlinksInPath().path == expected.path else { throw BackupError.invalid }
                                let fingerprint = try BackupFileDigest.read(url, maximumBytes: asset.kind == "pdf" ? 512 * 1024 * 1024 : UInt64(LibraryDisk.maximumDrawingBytes))
                                guard fingerprint.count == asset.count, fingerprint.digest == asset.digest else { throw BackupError.invalid }
                            }
                            for asset in installed { try fm.removeItem(at: asset.url(disk)) }
                        }
                    }
                    try fm.removeItem(at: stage)
                } catch { warnings += 1 }
            }
        } catch { warnings += 1 }
        return warnings == 0 ? nil : "\(warnings) unfinished restore workspace(s) were preserved because cleanup could not be proven safe. Existing library content remains available."
    }
}
