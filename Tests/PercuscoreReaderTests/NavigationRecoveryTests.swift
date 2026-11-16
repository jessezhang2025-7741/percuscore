import XCTest
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class NavigationRecoveryTests: XCTestCase {
    private func fixture(page: Int = 0) throws -> (LibraryStore, ReaderModel, LibraryDisk) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NavigationRecovery-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "Navigation recovery", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings.halfPageTurns = false })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        let session = try XCTUnwrap(ReadingSession(queue: [item], page: page))
        return (store, ReaderModel(store: store, session: session), disk)
    }
    func testForwardTurnRejectsCorruptConfirmedInkWithoutReplacingPageOrCanvas() throws {
        let (_, model, disk) = try fixture()
        let page = model.page, canvas = model.canvas, session = model.session
        try Data("invalid ink".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        model.turn(forward: true)
        XCTAssertEqual(model.session, session)
        XCTAssertTrue(model.page === page); XCTAssertTrue(model.canvas === canvas)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.seek(2)); model.turn(forward: true)
        XCTAssertEqual(model.pageIndex, 3)
    }
    func testBackwardTurnRejectsUnreadableDraftAndNavigationStillWorks() throws {
        let (_, model, disk) = try fixture(page: 2)
        let page = model.page, canvas = model.canvas, session = model.session
        let url = disk.inkURL(model.scoreID, page: 1, draft: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        model.turn(forward: false)
        XCTAssertEqual(model.session, session)
        XCTAssertTrue(model.page === page); XCTAssertTrue(model.canvas === canvas)
        model.turn(forward: true); XCTAssertEqual(model.pageIndex, 3)
    }
    func testBothTurnAndSeekDecodeDraftBeforeSwitching() throws {
        for seek in [false, true] {
            let (_, model, disk) = try fixture()
            let page = model.page, canvas = model.canvas
            try disk.writeInk(Data("invalid draft".utf8), scoreID: model.scoreID, page: 1, draft: true)
            if seek { XCTAssertFalse(model.seek(1)) } else { model.turn(forward: true) }
            XCTAssertEqual(model.pageIndex, 0)
            XCTAssertTrue(model.page === page); XCTAssertTrue(model.canvas === canvas)
            XCTAssertFalse(model.recoveryAvailable)
            XCTAssertTrue(model.seek(2))
        }
    }
    func testFailedTargetDoesNotCommitOutgoingAnnotationOrExitPerformance() throws {
        let (_, model, disk) = try fixture()
        try Data("invalid ink".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        model.beginAnnotation()
        let canvas = model.canvas
        model.turn(forward: true, annotationArrow: true)
        XCTAssertEqual(model.mode, .annotating); XCTAssertTrue(model.canvas === canvas)
        XCTAssertNil(try disk.readInk(scoreID: model.scoreID, page: 0))
        model.cancelAnnotation(); model.enterPerformance(); model.turn(forward: true)
        XCTAssertTrue(model.performance.isActive); XCTAssertEqual(model.pageIndex, 0)
        XCTAssertNotNil(model.page)
    }
    func testHalfTurnFailureKeepsTransitionAndCanReturnToFullPage() throws {
        let (store, model, disk) = try fixture()
        XCTAssertTrue(store.update { $0.settings.halfPageTurns = true })
        model.turn(forward: true)
        XCTAssertTrue(model.session.showingTransition)
        let session = model.session, page = model.page
        try Data("invalid ink".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        model.turn(forward: true)
        XCTAssertEqual(model.session, session); XCTAssertTrue(model.page === page)
        model.turn(forward: false)
        XCTAssertFalse(model.session.showingTransition); XCTAssertEqual(model.pageIndex, 0)
    }
    private func drawing() -> PKDrawing {
        let points = [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 5, height: 5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
                       path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }
    func testIgnoreMarkingsIsReadOnlyAndPreservesBothFilesAcrossNavigation() throws {
        let (_, model, disk) = try fixture()
        let bad = Data("bad confirmed".utf8), draft = drawing().dataRepresentation()
        try bad.write(to: disk.inkURL(model.scoreID, page: 1))
        try disk.writeInk(draft, scoreID: model.scoreID, page: 1, draft: true)
        let draftURL = disk.inkURL(model.scoreID, page: 1, draft: true)
        let draftFile = try Data(contentsOf: draftURL)
        model.turn(forward: true)
        XCTAssertTrue(try XCTUnwrap(model.navigationFailure).canIgnoreMarkings)
        XCTAssertTrue(model.ignoreFailedMarkings())
        XCTAssertEqual(model.pageIndex, 1); XCTAssertNotNil(model.page)
        XCTAssertTrue(model.ignoringMarkings); XCTAssertFalse(model.recoveryAvailable)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(model.canvas.drawingGestureRecognizer.isEnabled)
        model.beginAnnotation(); XCTAssertEqual(model.mode, .reading)
        model.beginCrop(); XCTAssertEqual(model.mode, .reading)
        model.flushDraft(); XCTAssertTrue(model.saveAnnotation())
        model.cancelAnnotation(); model.discardRecovery()
        XCTAssertTrue(model.seek(2)); XCTAssertFalse(model.ignoringMarkings)
        XCTAssertTrue(model.seek(1)); XCTAssertTrue(model.ignoringMarkings)
        XCTAssertEqual(try Data(contentsOf: disk.inkURL(model.scoreID, page: 1)), bad)
        XCTAssertEqual(try Data(contentsOf: draftURL), draftFile)
        let reopened = ReaderModel(store: model.store, session: model.session)
        XCTAssertNil(reopened.page); XCTAssertNotNil(reopened.navigationFailure)
    }
    func testSkipUsesFailedTargetAndPreservesDamagedBytesInBothDirections() throws {
        for forward in [true, false] {
            let (_, model, disk) = try fixture(page: forward ? 0 : 3)
            let failed = forward ? 1 : 2, expected = forward ? 2 : 1
            let bad = Data("bad ink".utf8), url = disk.inkURL(model.scoreID, page: failed)
            try bad.write(to: url)
            model.turn(forward: forward)
            XCTAssertTrue(model.canSkipFailedPage); XCTAssertTrue(model.skipFailedPage())
            XCTAssertEqual(model.pageIndex, expected); XCTAssertNotNil(model.page)
            XCTAssertNil(model.navigationFailure); XCTAssertFalse(model.ignoringMarkings)
            XCTAssertEqual(try Data(contentsOf: url), bad)
        }
    }
    func testRepeatedBadPagesKeepOriginalAndExcerptBoundaryDisablesSkip() throws {
        let (_, model, disk) = try fixture()
        var item = model.session.item; item.endPage = 2
        XCTAssertTrue(model.openSession(try XCTUnwrap(ReadingSession(queue: [item]))))
        for page in [1, 2] { try Data("bad".utf8).write(to: disk.inkURL(model.scoreID, page: page)) }
        let original = model.page
        model.turn(forward: true)
        XCTAssertFalse(model.skipFailedPage())
        XCTAssertEqual(model.pageIndex, 0); XCTAssertTrue(model.page === original)
        XCTAssertEqual(model.navigationFailure?.target.position.page, 2)
        XCTAssertFalse(model.canSkipFailedPage); XCTAssertFalse(model.skipFailedPage())
        model.clearNavigationFailure(); XCTAssertNil(model.navigationFailure)
        XCTAssertTrue(model.seek(0))
    }
    func testInitialCorruptDraftCanOpenWithoutMarkingsAndMissingPDFCannot() throws {
        let (_, model, disk) = try fixture()
        try disk.writeInk(Data("bad draft".utf8), scoreID: model.scoreID, page: 0, draft: true)
        let reopened = ReaderModel(store: model.store, session: model.session)
        XCTAssertNil(reopened.page); XCTAssertTrue(reopened.ignoreFailedMarkings())
        XCTAssertNotNil(reopened.page); XCTAssertTrue(reopened.ignoringMarkings)
        let missing = ReadingItem(scoreID: UUID(), title: "Missing", startPage: 0, endPage: 0)
        XCTAssertFalse(reopened.openSession(try XCTUnwrap(ReadingSession(queue: [missing]))))
        XCTAssertNotNil(reopened.page); XCTAssertEqual(reopened.scoreID, model.scoreID)
        XCTAssertFalse(try XCTUnwrap(reopened.navigationFailure).canIgnoreMarkings)
        XCTAssertFalse(reopened.ignoreFailedMarkings())
    }
    func testQueueFailureAndSkipRetainCorrectScoreAndRespectContinueSetting() throws {
        let (store, model, disk) = try fixture(page: 3)
        let next = Score(title: "Next score", pageCount: 4)
        try SampleScore.write(to: disk.pdfURL(for: next.id))
        XCTAssertTrue(store.update { $0.scores.append(next); $0.settings.continueSetlist = true })
        let nextItem = try XCTUnwrap(store.index.resolve(.init(scoreID: next.id)))
        let queue = try XCTUnwrap(ReadingSession(queue: [model.session.item, nextItem], page: 3))
        XCTAssertTrue(model.openSession(queue))
        try Data("bad".utf8).write(to: disk.inkURL(next.id, page: 0))
        let originalID = model.scoreID, page = model.page
        model.turn(forward: true)
        XCTAssertEqual(model.scoreID, originalID); XCTAssertTrue(model.page === page)
        XCTAssertEqual(model.navigationFailure?.target.item.scoreID, next.id)
        XCTAssertTrue(model.skipFailedPage())
        XCTAssertEqual(model.scoreID, next.id); XCTAssertEqual(model.pageIndex, 1)
        XCTAssertNotNil(model.page)
        XCTAssertTrue(store.update { $0.settings.continueSetlist = false })
        XCTAssertTrue(model.seek(0) == false)
        // Backward skip from a failed first page cannot cross into the prior queue item.
        XCTAssertFalse(model.canSkipFailedPage)
    }
    func testPreparedTargetDoesNotSwitchWhenOutgoingSaveFails() throws {
        let (_, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing()
        let original = model.page, canvas = model.canvas
        let url = disk.inkURL(model.scoreID, page: 0)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertFalse(model.seek(2))
        XCTAssertEqual(model.pageIndex, 0); XCTAssertTrue(model.page === original)
        XCTAssertTrue(model.canvas === canvas); XCTAssertEqual(model.mode, .annotating)
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
    }
    func testSamePageSeekKeepsLiveInkAndViewportAfterConfirmation() throws {
        let (_, model, disk) = try fixture()
        model.beginAnnotation(); model.canvas.drawing = drawing()
        model.viewport.scale = 2
        XCTAssertTrue(model.seek(0))
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1); XCTAssertEqual(model.viewport.scale, 2)
        XCTAssertEqual(model.mode, .reading)
        let saved = try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: model.scoreID, page: 0)))
        XCTAssertEqual(saved.strokes.count, 1)
    }
    func testValidTargetDraftOffersRecoveryOnlyAfterSuccessfulSwitch() throws {
        let (_, model, disk) = try fixture()
        try disk.writeInk(drawing().dataRepresentation(), scoreID: model.scoreID, page: 1, draft: true)
        model.turn(forward: true)
        XCTAssertEqual(model.pageIndex, 1); XCTAssertTrue(model.recoveryAvailable)
        XCTAssertNotNil(model.page); XCTAssertNil(model.navigationFailure)
        model.recoverDraft()
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1); XCTAssertEqual(model.mode, .annotating)
    }

    func testOutgoingSaveFailureDuringRecoveryShowsSaveErrorInsteadOfStaleTargetNotice() throws {
        let (_, model, disk) = try fixture()
        try Data("bad".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        model.beginAnnotation(); model.canvas.drawing = drawing()
        model.turn(forward: true, annotationArrow: true)
        XCTAssertNotNil(model.navigationFailure)
        let url = disk.inkURL(model.scoreID, page: 0)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertFalse(model.ignoreFailedMarkings())
        XCTAssertNil(model.navigationFailure, "A save failure must reach the ordinary save error / Retry UI")
        XCTAssertNotNil(model.errorMessage); XCTAssertEqual(model.saveState, .failed)
        XCTAssertEqual(model.mode, .annotating); XCTAssertEqual(model.pageIndex, 0)
        XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(model.retrySaving())
        model.turn(forward: true); XCTAssertNotNil(model.navigationFailure)
    }
    func testIgnoredMarkingsDoNotBreakHalfPagePreviewRendering() async throws {
        let (store, model, disk) = try fixture()
        try Data("bad".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        XCTAssertFalse(model.seek(1)); XCTAssertTrue(model.ignoreFailedMarkings())
        XCTAssertTrue(store.update { $0.settings.halfPageTurns = true })
        model.refreshSettings()
        for _ in 0..<50 {
            if model.transitionImage(next: false) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.transitionImage(next: false))
        model.turn(forward: true); XCTAssertTrue(model.session.showingTransition)
        model.turn(forward: true); XCTAssertEqual(model.pageIndex, 2)
        XCTAssertFalse(model.ignoringMarkings); XCTAssertNotNil(model.page)
    }

    func testRecoveryCropSaveFailureDoesNotRetainOldNavigationError() throws {
        let (store, model, disk) = try fixture()
        model.flushDraft()
        let indexURL = disk.root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        model.changeDivider(0.65, persist: true)
        try Data("bad".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        model.turn(forward: true)
        XCTAssertNotNil(model.navigationFailure)
        XCTAssertFalse(model.ignoreFailedMarkings())
        XCTAssertNil(model.navigationFailure)
        XCTAssertNil(model.errorMessage, "The store's current save error must not be shadowed by a retired navigation message")
        XCTAssertNotNil(store.errorMessage); XCTAssertEqual(model.saveState, .failed)
        XCTAssertEqual(model.pageIndex, 0); XCTAssertEqual(model.layout.divider, 0.65)
        try FileManager.default.removeItem(at: indexURL)
        XCTAssertTrue(model.retrySaving())
        XCTAssertEqual(store.score(model.scoreID)?.layouts[0]?.divider, 0.65)
    }
    func testHalfTurnPreparesNextMarkingsBeforeStartingTransition() throws {
        let (store, model, disk) = try fixture()
        XCTAssertTrue(store.update { $0.settings.halfPageTurns = true })
        try Data("bad".utf8).write(to: disk.inkURL(model.scoreID, page: 1))
        let original = model.page, session = model.session
        model.turn(forward: true)
        XCTAssertEqual(model.session, session); XCTAssertTrue(model.page === original)
        XCTAssertEqual(model.navigationFailure?.target.position.page, 1)
        XCTAssertTrue(model.ignoreFailedMarkings()); XCTAssertEqual(model.pageIndex, 1)
        XCTAssertFalse(model.session.showingTransition); XCTAssertTrue(model.ignoringMarkings)
    }

}
