import XCTest
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class DeviceAcceptanceNativeTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var build: AcceptanceBuild { AcceptanceBuild(version: "0.1.0", build: "1", commit: String(repeating: "a", count: 40), sourceState: "clean") }
    func testFixedFixtureContainsRotatedMarkedAndScannedWorksAndCrossWorkSetlist() throws {
        let root = try root()
        let manifest = try AcceptanceFixtures.build(at: root, scanPages: 6, dpi: 72)
        let disk = try LibraryDisk(root: root)
        let index = try disk.load()
        XCTAssertEqual(index.scores.count, 4)
        XCTAssertEqual(index.setlists.first?.entries.count, 4)
        let rotated = index.scores[1], marked = index.scores[2], scanned = index.scores[3]
        XCTAssertEqual(PDFDocument(url: disk.pdfURL(for: rotated.id))?.page(at: 1)?.rotation, 90)
        XCTAssertEqual(scanned.pageCount, 6)
        XCTAssertEqual(PDFDocument(url: disk.pdfURL(for: scanned.id))?.pageCount, 6)
        XCTAssertGreaterThan(marked.layouts[0]!.scale, 1)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: marked.id, page: 0))).strokes.count, 1)
        XCTAssertEqual(manifest.pdfSHA256.count, 4)
        XCTAssertEqual(try AcceptanceFixtures.verify(at: root).pdfSHA256, manifest.pdfSHA256)
    }
    func testChangedFixturePDFCannotPretendToMatchManifest() throws {
        let root = try root()
        _ = try AcceptanceFixtures.build(at: root, scanPages: 2, dpi: 72)
        let disk = try LibraryDisk(root: root), index = try disk.load()
        try Data("not a PDF".utf8).write(to: disk.pdfURL(for: index.scores[0].id))
        XCTAssertThrowsError(try AcceptanceFixtures.verify(at: root))
    }
    func testSessionSurvivesRelaunchAndBuildMismatchCannotEditOldResults() throws {
        let root = try root()
        let first = DeviceAcceptanceCoordinator(root: root, build: build)
        first.update { $0.record(id: "input-01", outcome: .failed, notes: "Lost first stroke") }
        let reopened = DeviceAcceptanceCoordinator(root: root, build: build)
        XCTAssertEqual(reopened.report.id, first.report.id)
        XCTAssertEqual(reopened.report.status, .failed)
        let other = AcceptanceBuild(version: "0.1.1", build: "2", commit: String(repeating: "b", count: 40), sourceState: "clean")
        let updated = DeviceAcceptanceCoordinator(root: root, build: other)
        XCTAssertFalse(updated.matchesCurrentBuild)
        updated.update { $0.operatorName = "Must not overwrite old source evidence" }
        XCTAssertEqual(updated.report.build, build)
        XCTAssertTrue(updated.report.operatorName.isEmpty)
        updated.newRun()
        XCTAssertEqual(updated.report.build, other)
        XCTAssertNotEqual(updated.report.id, first.report.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("reports/\(first.report.id.uuidString).json").path))
    }
    func testRunningRehearsalIsMarkedInterruptedAfterProcessReopen() throws {
        let root = try root()
        let first = DeviceAcceptanceCoordinator(root: root, build: build)
        first.update { $0.startRehearsal() }
        let reopened = DeviceAcceptanceCoordinator(root: root, build: build)
        XCTAssertTrue(reopened.report.rehearsalInterrupted)
        XCTAssertNil(reopened.report.rehearsalStartedAt)
        XCTAssertEqual(reopened.report.status, .incomplete)
    }
    func testChangedSystemCannotAddObservationsToAnOldEnvironment() throws {
        let root = try root()
        let first = DeviceAcceptanceCoordinator(root: root, build: build)
        first.update { $0.operatorName = "Previous operator" }
        let url = root.appendingPathComponent("session.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["systemVersion"] = "previous OS"
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        let reopened = DeviceAcceptanceCoordinator(root: root, build: build)
        XCTAssertFalse(reopened.canEdit)
        reopened.update { $0.operatorName = "New observations must use a new run" }
        XCTAssertEqual(reopened.report.operatorName, "Previous operator")
        XCTAssertTrue(reopened.newRun())
        XCTAssertTrue(reopened.canEdit)
        XCTAssertNotEqual(reopened.report.systemVersion, "previous OS")
    }
    func testNewRunCanRetryWhenPreviousArchiveAlreadyExists() throws {
        let root = try root()
        let coordinator = DeviceAcceptanceCoordinator(root: root, build: build)
        let archives = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let archive = archives.appendingPathComponent(coordinator.report.id.uuidString + ".json")
        let previousBytes = try Data(contentsOf: root.appendingPathComponent("session.json"))
        try previousBytes.write(to: archive)
        coordinator.update { $0.record(id: "input-01", outcome: .failed, notes: "Later observation") }
        let oldID = coordinator.report.id
        XCTAssertTrue(coordinator.newRun())
        XCTAssertNotEqual(coordinator.report.id, oldID)
        XCTAssertEqual(try Data(contentsOf: archive), previousBytes)
        let saved = try FileManager.default.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(try saved.contains { url in
            try JSONDecoder().decode(DeviceAcceptanceReport.self, from: Data(contentsOf: url)).status == .failed
        })
    }
    func testDiagnosticsRequireOptInAndExportContainsNoFixtureAssets() throws {
        let root = try root()
        let diagnostics = ReaderDiagnostics(root: root.appendingPathComponent("diagnostics"))
        diagnostics.record(.strokeBegan, state: .started, page: 1, item: 0)
        XCTAssertTrue(try diagnostics.events().isEmpty)
        diagnostics.enabled = true
        diagnostics.record(.strokeEnded, state: .succeeded, page: 1, item: 0)
        XCTAssertEqual(try diagnostics.events().count, 1)
        let coordinator = DeviceAcceptanceCoordinator(root: root.appendingPathComponent("acceptance"), build: build)
        let urls = try coordinator.export(diagnostics: diagnostics)
        XCTAssertEqual(Set(urls.map(\.pathExtension)), Set(["json", "md"]))
        XCTAssertEqual(urls.count, 3)
        let json = urls.first { $0.lastPathComponent == "report.json" }!
        XCTAssertEqual(try JSONDecoder().decode(DeviceAcceptanceReport.self, from: Data(contentsOf: json)).build, build)
        XCTAssertFalse(urls.contains { $0.pathExtension == "pdf" || $0.pathExtension == "drawing" })
    }
    func testRealReaderHooksRecordModePageSaveAndFocusMetadata() throws {
        let root = try root()
        _ = try AcceptanceFixtures.build(at: root.appendingPathComponent("library"), scanPages: 2, dpi: 72)
        let store = LibraryStore(root: root.appendingPathComponent("library"))
        let diagnostics = ReaderDiagnostics(root: root.appendingPathComponent("log"))
        diagnostics.enabled = true
        let score = store.index.scores[0]
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: 0, endPage: 3)]))
        let model = ReaderModel(store: store, session: session, diagnostics: diagnostics)
        model.beginAnnotation()
        model.canvasViewDidBeginUsingTool(model.canvas)
        model.canvasViewDrawingDidChange(model.canvas)
        model.canvasViewDidEndUsingTool(model.canvas)
        XCTAssertTrue(model.saveAnnotation())
        model.turn(forward: true)
        let events = try diagnostics.events()
        for kind: ReaderDiagnosticEvent.Kind in [.modeChanged, .pageLoaded, .saveDraft, .saveAnnotation, .strokeBegan, .strokeChanged, .strokeEnded] {
            XCTAssertTrue(events.contains { $0.kind == kind }, "Missing reader hook: \(kind)")
        }
        XCTAssertTrue(events.contains { $0.kind == .pageLoaded && $0.page == 2 })
        let surface = ScoreSurfaceView(model: model, displayOptions: {})
        surface.refresh()
        let done = expectation(description: "Deferred focus update")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(try diagnostics.events().contains { $0.kind == .focusUpdate && $0.state == .detached })
    }
}
