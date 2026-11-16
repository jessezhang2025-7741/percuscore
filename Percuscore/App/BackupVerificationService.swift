import Foundation
import UIKit

struct VerifiedBackup {
    let evidence: BackupVerificationEvidence
    let root: URL
}

enum BackupVerificationService {
    static func restoreSelectedFile(_ url: URL, workspace: URL) throws -> BackupVerification {
        guard !FileManager.default.fileExists(atPath: workspace.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: workspace) } }
        let copy = workspace.appendingPathComponent("selected.percuscorebackup")
        defer { try? FileManager.default.removeItem(at: copy) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do { try copyBounded(readable, to: copy) } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        let result = try LibraryBackup.verify(from: copy, at: workspace.appendingPathComponent("restored"))
        success = true; return result
    }
    private static func copyBounded(_ source: URL, to target: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= BackupFileDigest.maximumArchiveBytes else { throw BackupError.resourceLimit }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        var count: UInt64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            guard UInt64(data.count) <= BackupFileDigest.maximumArchiveBytes - count else { throw BackupError.resourceLimit }
            count += UInt64(data.count); try output.write(contentsOf: data)
        }
        try output.synchronize()
    }
    @MainActor
    static func evidence(_ verification: BackupVerification, id: UUID, records: BackupRecords) -> BackupVerificationEvidence {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let model = withUnsafePointer(to: &system.machine) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return BackupVerificationEvidence(verification: verification, build: .current, deviceModel: model, systemVersion: UIDevice.current.systemVersion,
            isSimulator: simulator, preparedAt: records.prepared?.sha256 == verification.archiveSHA256 ? records.prepared?.date : nil,
            exportedAt: records.exported?.sha256 == verification.archiveSHA256 ? records.exported?.date : nil, id: id)
    }
    @MainActor
    static func matchesCurrentEnvironment(_ evidence: BackupVerificationEvidence) -> Bool {
        let current = self.evidence(evidence.verification, id: evidence.id, records: BackupRecords())
        return evidence.build == current.build && evidence.deviceModel == current.deviceModel &&
            evidence.systemVersion == current.systemVersion && evidence.isSimulator == current.isSimulator
    }
    static func exportReport(_ evidence: BackupVerificationEvidence) throws -> [URL] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let json = root.appendingPathComponent("backup-verification.json"), markdown = root.appendingPathComponent("backup-verification.md")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(evidence).write(to: json, options: .atomic)
            try Data(evidence.markdown.utf8).write(to: markdown, options: .atomic)
            return [markdown, json]
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}
