import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class AnnotationCommitTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ReaderModel, LibraryDisk) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationCommit-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Commit consistency", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score] })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        let model = ReaderModel(store: store, session: try XCTUnwrap(ReadingSession(queue: [item])))
        model.flushDraft()
        return (store, model, disk)
    }
    private func drawing(strokes: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<strokes).map { i in
            let points = [CGPoint(x: 100, y: 100 + i * 100), CGPoint(x: 300, y: 150 + i * 100)]
                .enumerated().map {
                    PKStrokePoint(location: $0.element, timeOffset: Double($0.offset),
                        size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
            return PKStroke(ink: PKInk(.pen, color: .red),
                            path: PKStrokePath(controlPoints: points, creationDate: Date()))
        })
    }
    private func permissions(_ mode: Int, _ directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: directory.path)
    }
    private func committed(_ disk: LibraryDisk, _ model: ReaderModel) throws -> PKDrawing {
        try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: model.pageIndex)))
    }
    func testCleanupFailureThenCancelKeepsCommittedCanvasAndDiskConsistent() throws {
        let (_, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing(strokes: 1); model.flushDraft()
        defer { try? permissions(0o755, disk.recoveryDirectory) }
        try permissions(0o555, disk.recoveryDirectory)
        XCTAssertFalse(model.saveAnnotation())
        XCTAssertEqual(try committed(disk, model).strokes.count, 1)
        XCTAssertEqual(model.mode, .reading, "The ink is committed even if recovery-copy cleanup fails")
        XCTAssertEqual(model.saveState, .failed)
        try permissions(0o755, disk.recoveryDirectory)
        model.cancelAnnotation()
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(try committed(disk, model).strokes.count, 1)
        XCTAssertEqual(model.saveState, .saved)
        let reopened = ReaderModel(store: model.store, session: model.session)
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 1)
        XCTAssertFalse(reopened.recoveryAvailable)
    }
    func testRestartDoesNotOfferOlderDraftAfterConfirmedCommit() throws {
        let (_, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing(strokes: 1); model.flushDraft()
        model.canvas.drawing = drawing(strokes: 2)
        defer { try? permissions(0o755, disk.recoveryDirectory) }
        try permissions(0o555, disk.recoveryDirectory)
        XCTAssertFalse(model.saveAnnotation())
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.inkURL(model.scoreID, page: 0, draft: true).path))
        XCTAssertNil(try disk.readInk(scoreID: model.scoreID, page: 0, draft: true), "Physical stale copies must not become recovery data")
        let reopened = ReaderModel(store: model.store, session: model.session)
        XCTAssertNotNil(reopened.page)
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 2)
        XCTAssertFalse(reopened.recoveryAvailable)
        XCTAssertEqual(reopened.saveState, .failed, "Cleanup remains pending after restart")
    }
    func testCleanupRetryDoesNotRewriteConfirmedInk() throws {
        let (_, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing(strokes: 1); model.flushDraft()
        defer { try? permissions(0o755, disk.recoveryDirectory); try? permissions(0o755, disk.inkDirectory) }
        try permissions(0o555, disk.recoveryDirectory)
        XCTAssertFalse(model.saveAnnotation())
        let confirmed = try XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 0))
        try permissions(0o755, disk.recoveryDirectory); try permissions(0o555, disk.inkDirectory)
        XCTAssertTrue(model.retrySaving(), "Cleanup only needs to remove the stale copy, not rewrite Ink")
        XCTAssertEqual(try disk.readInk(scoreID: model.scoreID, page: 0), confirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.inkURL(model.scoreID, page: 0, draft: true).path))
        XCTAssertEqual(model.saveState, .saved)
    }
    func testNewDraftIdenticalToRetiredContentStillRemainsRecoverable() throws {
        let (_, model, disk) = try fixture(), oldDraft = drawing(strokes: 1)
        model.beginAnnotation(); model.canvas.drawing = oldDraft; model.flushDraft()
        model.canvas.drawing = drawing(strokes: 2)
        defer { try? permissions(0o755, disk.recoveryDirectory) }
        try permissions(0o555, disk.recoveryDirectory)
        XCTAssertFalse(model.saveAnnotation())
        try permissions(0o755, disk.recoveryDirectory)
        model.beginAnnotation(); model.canvas.drawing = oldDraft; model.flushDraft()
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(model.mode, .annotating, "Retry of cleanup must not confirm a later, unfinished edit")
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 0, draft: true))).strokes.count, 1)
        let reopened = ReaderModel(store: model.store, session: model.session)
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 2)
        XCTAssertTrue(reopened.recoveryAvailable)
        reopened.recoverDraft(); XCTAssertEqual(reopened.canvas.drawing.strokes.count, 1)
        reopened.cancelAnnotation()
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 2)
        XCTAssertEqual(try committed(disk, reopened).strokes.count, 2)
    }
    func testNormalCancellationPreservesEarlierConfirmedInk() throws {
        let (_, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing(strokes: 1)
        XCTAssertTrue(model.saveAnnotation())
        model.beginAnnotation(); model.canvas.drawing = drawing(strokes: 2); model.flushDraft()
        model.cancelAnnotation()
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(try committed(disk, model).strokes.count, 1)
        XCTAssertNil(try disk.readInk(scoreID: model.scoreID, page: 0, draft: true))
    }
    func testBackupDoesNotReviveRetiredDraft() async throws {
        let (store, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing(strokes: 1); model.flushDraft()
        model.canvas.drawing = drawing(strokes: 2)
        defer { try? permissions(0o755, disk.recoveryDirectory) }
        try permissions(0o555, disk.recoveryDirectory)
        XCTAssertFalse(model.saveAnnotation())
        let archive = try await store.createBackup()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let restoredStore = LibraryStore(root: root)
        let count = try await restoredStore.restoreBackup(from: archive)
        XCTAssertEqual(count, 1)
        let score = try XCTUnwrap(restoredStore.index.scores.first)
        let item = try XCTUnwrap(restoredStore.index.resolve(.init(scoreID: score.id)))
        let reopened = ReaderModel(store: restoredStore, session: try XCTUnwrap(ReadingSession(queue: [item])))
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 2)
        XCTAssertFalse(reopened.recoveryAvailable)
    }
}
