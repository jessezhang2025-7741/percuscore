import XCTest
@testable import PercuscoreCore

final class BackupEvidenceTests: XCTestCase {
    private func evidence(simulator: Bool = false) -> BackupVerificationEvidence {
        let result = BackupVerification(archiveSHA256: String(repeating: "a", count: 64), contentSHA256: String(repeating: "b", count: 64),
            verifiedAt: Date(), scoreCount: 2, setlistCount: 1, pdfCount: 2, savedInkCount: 2, draftCount: 1)
        return BackupVerificationEvidence(verification: result, build: .init(version: "0.1.0", build: "1", commit: String(repeating: "c", count: 40), sourceState: "clean"),
            deviceModel: "iPad13,16", systemVersion: "26.5", isSimulator: simulator, preparedAt: Date(), exportedAt: Date())
    }
    func testRestorationVerificationDoesNotAutomaticallyPassPhysicalFilesAndVisualChecks() {
        var record = evidence()
        XCTAssertEqual(record.physicalFilesStatus, .incomplete)
        for id in record.visualChecks.map(\.id) { record.recordVisual(id: id, outcome: .passed, notes: "Observed") }
        XCTAssertEqual(record.physicalFilesStatus, .incomplete)
        record.outsideAppConfirmed = true
        XCTAssertEqual(record.physicalFilesStatus, .passed)
        var simulator = evidence(simulator: true)
        simulator.outsideAppConfirmed = true
        for id in simulator.visualChecks.map(\.id) { simulator.recordVisual(id: id, outcome: .passed, notes: "") }
        XCTAssertEqual(simulator.physicalFilesStatus, .incomplete)
    }
    func testChangingVisualFailureToPassCannotEraseFailureHistory() {
        var record = evidence()
        record.recordVisual(id: "ink", outcome: .failed, notes: "Red ink missing")
        record.recordVisual(id: "ink", outcome: .passed, notes: "Retry")
        XCTAssertEqual(record.physicalFilesStatus, .failed)
    }
    func testVerificationWithoutKnownSystemExportRemainsPhysicalIncomplete() {
        let verified = evidence().verification
        var record = BackupVerificationEvidence(verification: verified, build: evidence().build, deviceModel: "iPad", systemVersion: "26.5", isSimulator: false)
        record.outsideAppConfirmed = true
        for id in record.visualChecks.map(\.id) { record.recordVisual(id: id, outcome: .passed, notes: "") }
        XCTAssertEqual(record.physicalFilesStatus, .incomplete)
        XCTAssertTrue(record.markdown.contains(verified.archiveSHA256))
    }
    func testPreparedExportedAndVerifiedIdentitiesRemainSeparateAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var records = BackupRecords()
        records.prepared = .init(sha256: String(repeating: "d", count: 64), date: Date())
        records.exported = .init(sha256: String(repeating: "e", count: 64), date: Date())
        records.verification = evidence()
        try disk.saveBackupRecords(records)
        let reopened = try LibraryDisk(root: root).backupRecords()
        XCTAssertEqual(reopened.prepared?.sha256, String(repeating: "d", count: 64))
        XCTAssertEqual(reopened.exported?.sha256, String(repeating: "e", count: 64))
        XCTAssertEqual(reopened.verification?.verification.archiveSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(reopened.verification?.physicalFilesStatus, .incomplete)
    }
}
