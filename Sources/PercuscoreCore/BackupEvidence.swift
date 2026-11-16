import Foundation

public struct BackupFileEvent: Codable, Sendable {
    public let sha256: String
    public let date: Date
    public let deletedScoreCount: Int?
    public let deletedAssetBytes: UInt64?
    public init(sha256: String, date: Date = Date(), deletedScoreCount: Int? = nil, deletedAssetBytes: UInt64? = nil) {
        self.sha256 = sha256; self.date = date
        self.deletedScoreCount = deletedScoreCount; self.deletedAssetBytes = deletedAssetBytes
    }
}

public struct BackupRecords: Codable, Sendable {
    public var prepared: BackupFileEvent?
    public var exported: BackupFileEvent?
    public var verification: BackupVerificationEvidence?
    public init() {}
}

public struct BackupVerificationEvidence: Codable, Identifiable, Sendable {
    public let format: String
    public let formatVersion: Int
    public let id: UUID
    public let verification: BackupVerification
    public let build: AcceptanceBuild
    public let deviceModel: String
    public let systemVersion: String
    public let isSimulator: Bool
    /// These timestamps refer only to the exact SHA-256 in verification.
    public let preparedAt: Date?
    public let exportedAt: Date?
    public var outsideAppConfirmed = false
    public var notes = ""
    public private(set) var visualChecks: [AcceptanceCheck]
    private static let required = [("ink", "Saved multicolor markings"), ("draft", "Unconfirmed draft recovery"),
        ("geometry", "PDF, crop and zoom alignment"), ("bookmarks", "Page and range bookmarks"), ("setlists", "Repeated cross-work setlist references")]
    public init(verification: BackupVerification, build: AcceptanceBuild, deviceModel: String, systemVersion: String,
                isSimulator: Bool, preparedAt: Date? = nil, exportedAt: Date? = nil, id: UUID = UUID()) {
        format = "percuscore-backup-verification"; formatVersion = 1; self.id = id
        self.verification = verification; self.build = build; self.deviceModel = deviceModel
        self.systemVersion = systemVersion; self.isSimulator = isSimulator; self.preparedAt = preparedAt; self.exportedAt = exportedAt
        visualChecks = Self.required.map { AcceptanceCheck(id: $0.0, title: $0.1) }
    }
    public mutating func recordVisual(id: String, outcome: AcceptanceOutcome, notes: String) {
        guard let i = visualChecks.firstIndex(where: { $0.id == id }) else { return }
        visualChecks[i].outcome = outcome; visualChecks[i].notes = String(notes.prefix(4000))
        visualChecks[i].everFailed = visualChecks[i].everFailed || outcome == .failed
        visualChecks[i].recordedAt = Date()
    }
    public var physicalFilesStatus: AcceptanceStatus {
        if visualChecks.contains(where: { $0.everFailed || $0.outcome == .failed }) { return .failed }
        guard format == "percuscore-backup-verification", formatVersion == 1,
              build.traceable, !isSimulator, !deviceModel.isEmpty, !systemVersion.isEmpty,
              exportedAt != nil, outsideAppConfirmed,
              verification.archiveSHA256.count == 64, verification.archiveSHA256.allSatisfy(\.isHexDigit),
              verification.contentSHA256.count == 64, verification.contentSHA256.allSatisfy(\.isHexDigit),
              visualChecks.count == Self.required.count, Set(visualChecks.map(\.id)) == Set(Self.required.map(\.0)),
              visualChecks.allSatisfy({ $0.outcome == .passed }) else { return .incomplete }
        return .passed
    }
    public var markdown: String {
        func date(_ value: Date?) -> String { value.map { ISO8601DateFormatter().string(from: $0) } ?? "Not recorded for this file" }
        func safe(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
        var lines = ["# Percuscore backup restore verification", "", "Run: \(id.uuidString)",
            "App: \(build.version) (\(build.build)); commit: \(build.commit); source: \(build.sourceState)",
            "Device: \(deviceModel); OS: \(systemVersion); Simulator: \(isSimulator)",
            "", "Archive SHA-256: \(verification.archiveSHA256)", "Canonical content SHA-256: \(verification.contentSHA256)",
            "File generated: \(date(preparedAt))", "System export completed: \(date(exportedAt))",
            "Restored, reopened and content compared: \(date(verification.verifiedAt))",
            "Scores/PDFs: \(verification.scoreCount)/\(verification.pdfCount); setlists: \(verification.setlistCount); saved ink: \(verification.savedInkCount); drafts: \(verification.draftCount)",
            "Recently Deleted: \(verification.deletedScoreCount.map(String.init) ?? "Not recorded") scores; asset bytes: \(verification.deletedAssetBytes.map(String.init) ?? "Not recorded")",
            "", "Physical Files and visual acceptance: **\(physicalFilesStatus.rawValue)** (operator observations)",
            "Operator confirms saved outside this App: \(outsideAppConfirmed)", "", "| Check | Result | Ever failed | Notes |", "|---|---|---|---|"]
        lines += visualChecks.map { "| \(safe($0.title)) | \($0.outcome.rawValue) | \($0.everFailed) | \(safe($0.notes)) |" }
        lines += ["", "Notes: \(notes)", "", "Automatic restoration does not prove physical Files operations or visual/Pencil quality. A Simulator cannot pass physical acceptance.",
                  "No PDF or handwriting content is included in this report. The selected backup was not added to the regular library."]
        return lines.joined(separator: "\n") + "\n"
    }
}

extension LibraryDisk {
    public func backupRecords() throws -> BackupRecords {
        let url = root.appendingPathComponent("backup-records.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return BackupRecords() }
        return try JSONDecoder().decode(BackupRecords.self, from: Self.readBounded(url, maximumBytes: 256 * 1024))
    }
    public func saveBackupRecords(_ records: BackupRecords) throws {
        let url = root.appendingPathComponent("backup-records.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(records)
        guard data.count <= 256 * 1024 else { throw LibraryError.corruptIndex }
        if FileManager.default.fileExists(atPath: url.path), (try? backupRecords()) == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LibraryError.corruptIndex }
            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("backup-records-damaged-\(UUID().uuidString).json"))
        }
        try data.write(to: url, options: .atomic)
    }
}
