import XCTest
import PDFKit
import PencilKit
@testable import Percuscore

@MainActor
final class PageNavigatorTests: XCTestCase {
    private func fixture(start: Int = 0, end: Int = 3) throws -> (LibraryStore, ReaderModel) {
        let store = LibraryStore()
        let score = Score(title: "Navigation practice", pageCount: 4)
        try SampleScore.write(to: XCTUnwrap(store.disk).pdfURL(for: score.id))
        XCTAssertTrue(store.update { $0.scores = [score]; $0.settings = ReaderSettings() })
        let session = try XCTUnwrap(ReadingSession(queue: [.init(scoreID: score.id, title: score.title, startPage: start, endPage: end)]))
        return (store, ReaderModel(store: store, session: session))
    }

    func testTypedPagesUsePDFNumbersAndRejectInvalidOrOutOfExcerptInput() throws {
        let (_, model) = try fixture(start: 1, end: 2)
        let index = PageNavigatorIndex(document: try model.document(model.scoreID), item: model.session.item, bookmarks: [])
        XCTAssertEqual(index.pages, [1, 2])
        XCTAssertEqual(index.target(for: " 2\n"), 1)
        XCTAssertEqual(index.target(for: "03"), 2)
        for input in ["", "1", "4", "0", "-2", "2.5", "abc", "9999999999999999999999999999"] {
            XCTAssertNil(index.target(for: input), input)
        }
    }

    func testIndexReadsNestedPDFOutlineAndHighlightsValidBookmarks() throws {
        let (_, model) = try fixture(start: 1)
        let document = try model.document(model.scoreID)
        let root = PDFOutline(), group = PDFOutline(), child = PDFOutline(), first = PDFOutline()
        group.label = "Suite"
        child.label = "II. Adagio"
        child.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: 2)), at: .zero))
        first.label = "I. Allegro"
        first.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: .zero)
        group.insertChild(child, at: 0); root.insertChild(first, at: 0); root.insertChild(group, at: 1)
        document.outlineRoot = root
        let bookmarks: [ScoreBookmark] = [.init(title: "Cue B", startPage: 1), .init(title: "Finale", startPage: 3, endPage: 3),
            .init(title: "Outside excerpt", startPage: 0), .init(title: "Broken", startPage: 99)]
        let index = PageNavigatorIndex(document: document, item: model.session.item, bookmarks: bookmarks)
        XCTAssertEqual(index.bookmarks.map(\.title), ["Cue B", "Finale"])
        XCTAssertEqual(index.sections.map(\.title), ["II. Adagio"])
        XCTAssertEqual(index.sections.map(\.page), [2])
        XCTAssertEqual(index.sections.first?.depth, 1)
        XCTAssertEqual(index.locations(on: 1).map(\.title), ["Cue B"])
        XCTAssertEqual(index.locations(on: 2).map(\.title), ["II. Adagio"])
        XCTAssertEqual(Set(index.locations.map(\.id)).count, 3)
    }

    func testRangeBookmarksAreClippedAndInvalidMetadataCannotCreatePhantomPages() throws {
        let (_, model) = try fixture(start: 1, end: 2)
        let item = ReadingItem(scoreID: model.scoreID, title: "Stale count", startPage: 1, endPage: 999)
        let index = PageNavigatorIndex(document: try model.document(model.scoreID), item: item,
            bookmarks: [.init(title: "Movement", startPage: 1, endPage: 3)])
        XCTAssertEqual(index.pages, [1, 2, 3])
        let excerpt = PageNavigatorIndex(document: try model.document(model.scoreID), item: model.session.item,
            bookmarks: [.init(title: "Movement", startPage: 1, endPage: 3)])
        XCTAssertEqual(excerpt.bookmarks.first?.endPage, 2)
        XCTAssertNil(excerpt.target(for: "4"))
    }

    func testIndexReadsPersistedPDFOutlineFromAnImportedFile() throws {
        let (store, model) = try fixture()
        let url = try XCTUnwrap(store.fileURL(model.scoreID))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: url) { context in
            for _ in 0..<4 { context.beginPage() }
            CGPDFContextSetOutline(context.cgContext, [kCGPDFOutlineChildren as String: [
                [kCGPDFOutlineTitle as String: "I. Allegro", kCGPDFOutlineDestination as String: 1],
                [kCGPDFOutlineTitle as String: "II. Adagio", kCGPDFOutlineDestination as String: 3]
            ]] as CFDictionary)
        }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let index = PageNavigatorIndex(document: document, item: model.session.item, bookmarks: [])
        XCTAssertEqual(index.sections.map(\.title), ["I. Allegro", "II. Adagio"])
        XCTAssertEqual(index.sections.map(\.page), [0, 2])
    }

    func testSeekRejectsPagesOutsideExcerptWithoutSavingOrMoving() throws {
        let (store, model) = try fixture(start: 1, end: 2)
        model.beginAnnotation()
        model.seek(0)
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertEqual(model.mode, .annotating)
        XCTAssertNil(try store.disk?.readInk(scoreID: model.scoreID, page: 1))
    }

    func testSeekDoesNotNavigateDuringImport() throws {
        let (store, model) = try fixture()
        store.isImporting = true
        model.seek(2)
        XCTAssertEqual(model.pageIndex, 0)
    }

    func testFailedInkSaveKeepsTheCurrentAnnotationOpen() throws {
        let (store, model) = try fixture()
        let url = try XCTUnwrap(store.disk).inkURL(model.scoreID, page: 0)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        model.beginAnnotation()
        XCTAssertFalse(model.seek(2))
        XCTAssertEqual(model.pageIndex, 0)
        XCTAssertEqual(model.mode, .annotating)
        XCTAssertNotNil(model.errorMessage)
    }

    func testUnreadableTargetInkOrDraftDoesNotReplaceTheCurrentPage() throws {
        let (store, model) = try fixture()
        let disk = try XCTUnwrap(store.disk)
        let original = model.page
        for draft in [false, true] {
            let url = disk.inkURL(model.scoreID, page: 2, draft: draft)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(model.seek(2))
            XCTAssertEqual(model.pageIndex, 0)
            XCTAssertTrue(model.page === original)
            try FileManager.default.removeItem(at: url)
        }
        try Data("invalid ink".utf8).write(to: disk.inkURL(model.scoreID, page: 2))
        XCTAssertFalse(model.seek(2))
        XCTAssertEqual(model.pageIndex, 0)
        XCTAssertTrue(model.page === original)
        try FileManager.default.removeItem(at: disk.inkURL(model.scoreID, page: 2))
        XCTAssertTrue(model.seek(1))
        XCTAssertEqual(model.pageIndex, 1)
    }

    func testThumbnailsReadThePDFAndRejectUnavailablePages() async throws {
        let (store, model) = try fixture()
        let provider = PageThumbnailProvider(url: try XCTUnwrap(store.fileURL(model.scoreID)))
        let image = await provider.image(for: 2)
        XCTAssertNotNil(image?.cgImage)
        let negative = await provider.image(for: -1)
        let missing = await provider.image(for: 4)
        XCTAssertNil(negative); XCTAssertNil(missing)
    }

    func testSeekSavesCurrentInkAndRestoresTargetViewport() throws {
        let (store, model) = try fixture()
        var view = PageViewport(); view.scale = 2; view.offsetY = 0.15
        XCTAssertTrue(store.update { $0.scores[0].viewports[2] = view })
        model.beginAnnotation()
        let points = [CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i), size: CGSize(width: 8, height: 8), opacity: 1,
                force: 1, azimuth: 0, altitude: .pi / 2)
        }
        model.canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        model.seek(2)
        XCTAssertEqual(model.pageIndex, 2)
        XCTAssertEqual(model.viewport, view)
        XCTAssertTrue(model.canvas.drawing.strokes.isEmpty)
        let saved = try PKDrawing(data: XCTUnwrap(store.disk?.readInk(scoreID: model.scoreID, page: 0)))
        XCTAssertEqual(saved.strokes.count, 1)
    }
}
