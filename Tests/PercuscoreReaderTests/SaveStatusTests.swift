import XCTest
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class SaveStatusTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ReaderModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SaveStatus-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Save status", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score] })
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 3)]))
        return (store, ReaderModel(store: store, session: session))
    }

    func testDrawingShowsSavingThenSavedAfterDraftReachesDisk() throws {
        let (store, model) = try fixture()
        model.flushDraft()
        model.beginAnnotation()
        model.canvasViewDidBeginUsingTool(model.canvas)
        model.canvasViewDrawingDidChange(model.canvas)
        XCTAssertEqual(model.saveState, .saving)
        model.canvasViewDidEndUsingTool(model.canvas)
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertNotNil(try store.disk?.readInk(scoreID: model.scoreID, page: 0, draft: true))
        XCTAssertEqual(model.mode, .annotating)
    }

    func testDraftFailureSurvivesAReadingPositionSaveAndCanBeRetried() throws {
        let (store, model) = try fixture()
        let draft = try XCTUnwrap(store.disk).inkURL(model.scoreID, page: 0, draft: true)
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        model.beginAnnotation(); model.flushDraft()
        XCTAssertEqual(model.saveState, .failed)
        model.viewport.scale = 2; model.viewport.offsetX = 0.1; model.viewport.offsetY = 0.1
        model.rememberViewport()
        XCTAssertEqual(model.saveState, .failed)
        try FileManager.default.removeItem(at: draft)
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertNotNil(try store.disk?.readInk(scoreID: model.scoreID, page: 0, draft: true))
        XCTAssertEqual(store.score(model.scoreID)?.viewports[0]?.scale, 2)
    }

    func testFailedReadingPositionIsNotMaskedByASuccessfulDraftAndRetryPersistsIt() throws {
        let (store, model) = try fixture()
        model.flushDraft()
        let indexURL = try XCTUnwrap(store.disk).root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        model.viewport.scale = 2; model.viewport.offsetX = 0.1; model.viewport.offsetY = 0.1
        model.rememberViewport(); model.beginAnnotation(); model.flushDraft()
        XCTAssertEqual(model.saveState, .failed)
        XCTAssertNotNil(try store.disk?.readInk(scoreID: model.scoreID, page: 0, draft: true))
        try FileManager.default.removeItem(at: indexURL)
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(model.saveState, .saved)
        let persisted = try XCTUnwrap(store.disk).load()
        XCTAssertEqual(persisted.scores[0].viewports[0]?.scale, 2)
    }

    func testConfirmedInkFailureRetainsAnnotationAndCancellationClearsItsStatus() throws {
        let (store, model) = try fixture()
        model.flushDraft(); model.beginAnnotation()
        let ink = try XCTUnwrap(store.disk).inkURL(model.scoreID, page: 0)
        try FileManager.default.createDirectory(at: ink, withIntermediateDirectories: true)
        XCTAssertFalse(model.saveAnnotation())
        XCTAssertEqual(model.saveState, .failed)
        XCTAssertEqual(model.mode, .annotating)
        model.cancelAnnotation()
        XCTAssertEqual(model.mode, .reading)
        XCTAssertEqual(model.saveState, .saved)
    }

    func testCropFailureRetainsEditThenRetrySavesIt() throws {
        let (store, model) = try fixture()
        model.flushDraft(); model.beginCrop(); model.layout.rotation = 2
        let indexURL = try XCTUnwrap(store.disk).root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        model.saveCrop()
        XCTAssertEqual(model.saveState, .failed)
        XCTAssertEqual(model.mode, .cropping)
        try FileManager.default.removeItem(at: indexURL)
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertEqual(model.mode, .reading)
        XCTAssertEqual(store.score(model.scoreID)?.layouts[0]?.rotation, 2)
    }

    func testDraftSaveCannotHideFailedConfirmationAndRetryConfirmsTheInk() throws {
        let (store, model) = try fixture()
        model.flushDraft(); model.beginAnnotation()
        let ink = try XCTUnwrap(store.disk).inkURL(model.scoreID, page: 0)
        try FileManager.default.createDirectory(at: ink, withIntermediateDirectories: true)
        XCTAssertFalse(model.saveAnnotation())
        model.flushDraft()
        XCTAssertEqual(model.saveState, .failed)
        try FileManager.default.removeItem(at: ink)
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(model.mode, .reading)
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertNotNil(try store.disk?.readInk(scoreID: model.scoreID, page: 0))
        XCTAssertNil(try store.disk?.readInk(scoreID: model.scoreID, page: 0, draft: true))
    }

    func testFailedDividerSaveCannotLoseItsPageWhenTurningOrSeeking() throws {
        let (store, model) = try fixture()
        model.flushDraft()
        let indexURL = try XCTUnwrap(store.disk).root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        model.changeDivider(0.65, persist: true)
        XCTAssertEqual(model.saveState, .failed)
        model.turn(forward: true)
        XCTAssertEqual(model.pageIndex, 0)
        XCTAssertFalse(model.seek(2))
        XCTAssertEqual(model.pageIndex, 0)
        try FileManager.default.removeItem(at: indexURL)
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertEqual(store.score(model.scoreID)?.layouts[0]?.divider, 0.65)
        XCTAssertTrue(model.seek(2))
        XCTAssertNil(store.score(model.scoreID)?.layouts[2])
    }

    func testNewCropCannotTreatFailedDividerAsASavedBaseline() throws {
        let (store, model) = try fixture()
        model.flushDraft()
        let indexURL = try XCTUnwrap(store.disk).root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        model.changeDivider(0.65, persist: true)
        model.beginCrop()
        XCTAssertEqual(model.mode, .reading)
        XCTAssertEqual(model.saveState, .failed)
        try FileManager.default.removeItem(at: indexURL)
        model.beginCrop()
        XCTAssertEqual(model.mode, .cropping)
        model.layout.rotation = 2
        model.cancelCrop()
        XCTAssertEqual(model.layout.divider, 0.65)
        XCTAssertEqual(model.layout.rotation, 0)
        XCTAssertEqual(store.score(model.scoreID)?.layouts[0]?.divider, 0.65)
        XCTAssertEqual(model.saveState, .saved)
    }

    func testReplacingReaderSessionMustSaveTheOutgoingLayoutFirst() throws {
        let (store, model) = try fixture()
        model.flushDraft()
        let disk = try XCTUnwrap(store.disk)
        let sourceID = model.scoreID
        let next = Score(title: "Dropped PDF", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: next.id))
        XCTAssertTrue(store.update { $0.scores.append(next) })
        let indexURL = disk.root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        model.changeDivider(0.65, persist: true)
        XCTAssertFalse(model.prepareForPageChange())
        XCTAssertEqual(model.scoreID, sourceID)
        XCTAssertEqual(model.saveState, .failed)
        try FileManager.default.removeItem(at: indexURL)
        XCTAssertTrue(model.prepareForPageChange())
        model.session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: next.id, title: next.title, startPage: 0, endPage: 3)]))
        model.loadCurrentPage(); model.flushDraft()
        XCTAssertEqual(store.score(sourceID)?.layouts[0]?.divider, 0.65)
        XCTAssertNil(store.score(next.id)?.layouts[0])
        XCTAssertEqual(model.layout.divider, 0.5)
        XCTAssertEqual(model.saveState, .saved)
    }

    func testRestoringBackupKeepsThisDevicesOwnExportHistory() async throws {
        let (store, _) = try fixture()
        try store.completeBackupExport(saved: true, at: Date(timeIntervalSince1970: 100))
        let url = try await store.createBackup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let newer = Date(timeIntervalSince1970: 200)
        try store.completeBackupExport(saved: true, at: newer)
        _ = try await store.restoreBackup(from: url)
        store.reload()
        XCTAssertEqual(store.lastBackupExportAt, newer)
    }

    func testPreparingAndCancellingBackupDoNotRecordAnExport() async throws {
        let (store, _) = try fixture()
        XCTAssertNil(store.lastBackupExportAt)
        let url = try await store.createBackup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.lastBackupExportAt)
        try store.completeBackupExport(saved: false, at: Date(timeIntervalSince1970: 100))
        store.reload()
        XCTAssertNil(store.lastBackupExportAt)
    }

    func testSuccessfulBackupTimeSurvivesReopenAndLaterCancellation() throws {
        let (store, _) = try fixture()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.completeBackupExport(saved: true, at: date)
        XCTAssertEqual(store.lastBackupExportAt, date)
        try store.completeBackupExport(saved: false, at: date.addingTimeInterval(60))
        let reopened = LibraryStore(root: try XCTUnwrap(store.disk).root)
        XCTAssertTrue(reopened.isReady)
        XCTAssertEqual(reopened.lastBackupExportAt, date)
    }

    func testBackupHistoryWriteFailureDoesNotClaimANewSuccessfulTime() throws {
        let (store, _) = try fixture()
        let root = try XCTUnwrap(store.disk).root
        let history = root.appendingPathComponent("backup-export.json")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.completeBackupExport(saved: true))
        XCTAssertNil(store.lastBackupExportAt)
        let reopened = LibraryStore(root: root)
        XCTAssertTrue(reopened.isReady)
        XCTAssertTrue(reopened.backupHistoryUnavailable)
        XCTAssertNil(reopened.lastBackupExportAt)
    }
}
