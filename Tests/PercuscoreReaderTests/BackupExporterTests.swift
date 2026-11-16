import XCTest
import UIKit
@testable import Percuscore

@MainActor
final class BackupExporterTests: XCTestCase {
    func testCancelledAndEmptyPickerCallbacksDoNotRecordSuccess() throws {
        var outcomes: [Bool] = []
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.percuscorebackup")
        try Data("export fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let coordinator = BackupFileExporter.Coordinator { outcomes.append($0) }
        coordinator.documentPicker(picker, didPickDocumentsAt: [])
        coordinator.documentPickerWasCancelled(picker)
        XCTAssertEqual(outcomes, [false])
    }

    func testSuccessfulPickerCallbackCompletesExactlyOnce() throws {
        var outcomes: [Bool] = []
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.percuscorebackup")
        try Data("export fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let coordinator = BackupFileExporter.Coordinator { outcomes.append($0) }
        coordinator.documentPicker(picker, didPickDocumentsAt: [url])
        coordinator.documentPicker(picker, didPickDocumentsAt: [url])
        coordinator.documentPickerWasCancelled(picker)
        XCTAssertEqual(outcomes, [true])
    }
}
