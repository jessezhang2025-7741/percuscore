import XCTest
@testable import PercuscoreCore

final class ViewportTests: XCTestCase {
    func testSavedManualViewSurvivesScoreDecodeAndReencode() throws {
        let score = Score(title: "Saved view", pageCount: 3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(score)) as? [String: Any])
        json["viewports"] = ["1": ["scale": 2.5, "offsetX": 0.2, "offsetY": -0.3]]
        let decoded = try JSONDecoder().decode(Score.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let views = try XCTUnwrap(encoded["viewports"] as? [String: Any])
        let page = try XCTUnwrap(views["1"] as? [String: Double])
        XCTAssertEqual(page["scale"], 2.5)
        XCTAssertEqual(page["offsetX"], 0.2)
        XCTAssertEqual(page["offsetY"], -0.3)
    }

    func testOldScoresWithoutViewsStillDecode() throws {
        let score = Score(title: "Old score", pageCount: 3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(score)) as? [String: Any])
        json.removeValue(forKey: "viewports")
        let decoded = try JSONDecoder().decode(Score.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.viewports.isEmpty)
        XCTAssertEqual(decoded.id, score.id)
    }

    func testViewOnlyUpdatesKeepSeparatePagesAndScoresAndOtherMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var index = LibraryIndex()
        var first = Score(title: "First", pageCount: 3)
        var crop = PageLayout(); crop.scale = 1.5; crop.rotation = 3
        first.layouts[0] = crop
        let second = Score(title: "Second", pageCount: 3)
        index.scores = [first, second]
        var a = PageViewport(); a.scale = 2; a.offsetX = 0.2; a.offsetY = -0.3
        var b = PageViewport(); b.scale = 3; b.offsetX = -0.4; b.offsetY = 0.5
        var buffer = ReadingProgressBuffer()
        buffer.recordViewport(a, scoreID: first.id, page: 0)
        buffer.recordViewport(b, scoreID: first.id, page: 1)
        buffer.recordViewport(b, scoreID: second.id, page: 0)
        buffer.recordViewport(b, scoreID: first.id, page: 99)
        index.scores[0].title = "Edited metadata"
        XCTAssertFalse(buffer.isEmpty)
        buffer.apply(to: &index); try disk.save(index)
        let reopened = try disk.load()
        XCTAssertEqual(reopened.scores[0].viewports, [0: a, 1: b])
        XCTAssertEqual(reopened.scores[1].viewports, [0: b])
        XCTAssertEqual(reopened.scores[0].layouts[0], crop)
        XCTAssertEqual(reopened.scores[0].title, "Edited metadata")
        buffer.removeAll(); XCTAssertTrue(buffer.isEmpty)
    }

    func testUnsafeViewportValuesNormalizeToAUsablePage() {
        var value = PageViewport(); value.scale = .nan; value.offsetX = .infinity; value.offsetY = -.infinity
        value.normalize(); XCTAssertEqual(value, PageViewport())
        value.scale = 100; value.offsetX = 10; value.offsetY = -10
        value.normalize()
        XCTAssertEqual(value.scale, 4); XCTAssertEqual(value.offsetX, 1.5); XCTAssertEqual(value.offsetY, -1.5)
    }
}
