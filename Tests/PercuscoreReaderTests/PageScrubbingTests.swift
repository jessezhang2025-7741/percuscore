import XCTest
import SwiftUI
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class PageScrubbingTests: XCTestCase {
    func testNonmodalNavigationFailureKeepsKeyboardFocusAndBackwardTurnWorks() async throws {
        let (store, initial) = try fixture(), disk = try XCTUnwrap(store.disk)
        let invalidInk = Data("invalid ink".utf8)
        XCTAssertThrowsError(try PKDrawing(data: invalidInk))
        try invalidInk.write(to: disk.inkURL(initial.item.scoreID, page: 3))
        let session = try XCTUnwrap(ReadingSession(queue: initial.queue, page: 2))
        let host = UIHostingController(rootView: ReaderView(store: store, session: session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
        let surface = try XCTUnwrap(views(host.view).compactMap { $0 as? ScoreSurfaceView }.first)
        let page = try XCTUnwrap(views(surface).first { $0.accessibilityLabel == "Score page" })
        XCTAssertTrue(surface.isFirstResponder)
        let forward = try XCTUnwrap(surface.keyCommands?.first { $0.input == UIKeyCommand.inputRightArrow })
        XCTAssertTrue(surface.responds(to: forward.action))
        surface.perform(forward.action, with: forward)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(surface.isFirstResponder, "Nonmodal failure notice must not disable keyboard/pedal input")
        XCTAssertTrue((page.accessibilityValue ?? "").contains("page 3 of 120"), page.accessibilityValue ?? "nil")
        let backward = try XCTUnwrap(surface.keyCommands?.first { $0.input == UIKeyCommand.inputLeftArrow })
        surface.perform(backward.action, with: backward)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue((page.accessibilityValue ?? "").contains("page 2 of 120"), page.accessibilityValue ?? "nil")
    }

    private func fixture() throws -> (LibraryStore, ReadingSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Scrubbing-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), disk = try XCTUnwrap(store.disk)
        let score = Score(title: "120-page scrubbing fixture", pageCount: 120)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: disk.pdfURL(for: score.id)) { context in
            for page in 1...120 {
                context.beginPage()
                "Synthetic page \(page)".draw(at: CGPoint(x: 50, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        XCTAssertTrue(store.update { $0.scores = [score] })
        let item = try XCTUnwrap(store.index.resolve(.init(scoreID: score.id)))
        return (store, try XCTUnwrap(ReadingSession(queue: [item])))
    }
    func testReaderChromeAvoidsNativeGlassHostingOnTiledPaper() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native glass requires iOS 26") }
        let (store, session) = try fixture()
        let host = UIHostingController(rootView: ReaderView(store: store, session: session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
        let effects = views(host.view).compactMap { ($0 as? UIVisualEffectView)?.effect }
        let nativeGlass = effects.filter { $0 is UIGlassEffect || $0 is UIGlassContainerEffect }
        XCTAssertFalse(effects.isEmpty, "The reader must retain its material-backed controls")
        let glassOwners = views(host.view).filter { view in
            guard let effect = (view as? UIVisualEffectView)?.effect else { return false }
            return effect is UIGlassEffect || effect is UIGlassContainerEffect
        }.map { view -> String in
            var names: [String] = []; var next: UIView? = view
            for _ in 0..<6 { if let node = next { names.append(String(describing: type(of: node))); next = node.superview } }
            return names.joined(separator: " → ")
        }
        XCTAssertTrue(nativeGlass.isEmpty, "Unexpected native glass owners: \(glassOwners)")
    }
    func testBurstSeeksKeepFinalPageAndSavedMarkings() async throws {
        let (store, session) = try fixture(), disk = try XCTUnwrap(store.disk)
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 100, y: 100), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
            PKStrokePoint(location: CGPoint(x: 300, y: 100), timeOffset: 1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        ], creationDate: Date()))])
        try disk.writeInk(ink.dataRepresentation(), scoreID: session.item.scoreID, page: 119)
        let model = ReaderModel(store: store, session: session)
        for i in 0..<100 { XCTAssertTrue(model.seek((i * 31) % 120)) }
        XCTAssertTrue(model.seek(119)); model.flushDraft()
        XCTAssertEqual(model.pageIndex, 119); XCTAssertEqual(model.canvas.drawing.strokes.count, 1)
        let reopened = LibraryStore(root: disk.root)
        XCTAssertEqual(reopened.score(session.item.scoreID)?.lastPage, 119)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(disk.readInk(scoreID: session.item.scoreID, page: 119))).strokes.count, 1)
    }
}
