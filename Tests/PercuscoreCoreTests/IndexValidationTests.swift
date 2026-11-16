import XCTest
@testable import PercuscoreCore

final class IndexValidationTests: XCTestCase {
    private func disk() throws -> LibraryDisk {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexValidation-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LibraryDisk(root: root)
    }
    private func fixture() -> LibraryIndex {
        var index = LibraryIndex(), score = Score(title: "Rehearsal", pageCount: 4)
        score.lastOpenedAt = Date(); score.lastPage = 2
        score.bookmarks = [.init(title: "Excerpt", startPage: 1, endPage: 3)]
        score.layouts[1] = PageLayout(); score.viewports[2] = PageViewport()
        index.scores = [score]
        var list = ScoreSetlist(title: "Concert")
        list.entries = [.init(scoreID: score.id, bookmarkID: score.bookmarks[0].id)]
        index.setlists = [list]
        return index
    }
    private func write(_ index: LibraryIndex, to disk: LibraryDisk, backup: Bool = false) throws -> Data {
        let data = try JSONEncoder().encode(index)
        try data.write(to: disk.root.appendingPathComponent(backup ? "library.backup.json" : "library.json"))
        return data
    }
    private func corruptVariants() -> [(String, LibraryIndex)] {
        let edits: [(String, (inout LibraryIndex) -> Void)] = [
            ("overflow last page", { $0.scores[0].lastPage = Int.max }),
            ("negative last page", { $0.scores[0].lastPage = -1 }),
            ("past last page", { $0.scores[0].lastPage = 4 }),
            ("zero page count", { $0.scores[0].pageCount = 0 }),
            ("negative page count", { $0.scores[0].pageCount = -1 }),
            ("unsafe slider page count", { $0.scores[0].pageCount = Int.max }),
            ("duplicate score", { $0.scores.append($0.scores[0]) }),
            ("duplicate setlist", { $0.setlists.append($0.setlists[0]) }),
            ("duplicate bookmark", { $0.scores[0].bookmarks.append($0.scores[0].bookmarks[0]) }),
            ("invalid bookmark start", { $0.scores[0].bookmarks[0].startPage = -1 }),
            ("invalid bookmark end", { $0.scores[0].bookmarks[0].endPage = Int.max }),
            ("reversed bookmark range", { $0.scores[0].bookmarks[0].endPage = 0 }),
            ("empty bookmark title", { $0.scores[0].bookmarks[0].title = "  " }),
            ("invalid layout page", { $0.scores[0].layouts[-1] = PageLayout() }),
            ("past layout page", { $0.scores[0].layouts[4] = PageLayout() }),
            ("extreme divider", { $0.scores[0].layouts[1]!.divider = 1e100 }),
            ("invalid crop scale", { $0.scores[0].layouts[1]!.scale = 0 }),
            ("invalid crop offset", { $0.scores[0].layouts[1]!.offsetX = 2 }),
            ("invalid crop rotation", { $0.scores[0].layouts[1]!.rotation = 90 }),
            ("invalid viewport page", { $0.scores[0].viewports[4] = PageViewport() }),
            ("invalid viewport scale", { $0.scores[0].viewports[2]!.scale = 5 }),
            ("invalid viewport offset", { $0.scores[0].viewports[2]!.offsetY = 1 }),
            ("duplicate entry", { $0.setlists[0].entries.append($0.setlists[0].entries[0]) }),
            ("missing entry score", { $0.setlists[0].entries[0].scoreID = UUID() }),
            ("missing entry bookmark", { $0.setlists[0].entries[0].bookmarkID = UUID() }),
            ("duplicate preset", { $0.settings.presets.append($0.settings.presets[0]) }),
            ("invalid preset width", { $0.settings.presets[0].width = 1e100 }),
            ("invalid preset opacity", { $0.settings.presets[0].opacity = -1 }),
        ]
        return edits.map { name, edit in var index = fixture(); edit(&index); return (name, index) }
    }
    func testSemanticCorruptionWithoutBackupIsRejectedWithoutChangingFiles() throws {
        for (name, invalid) in corruptVariants() {
            let disk = try disk(), original = try write(invalid, to: disk)
            let pdf = Data("PDF-preserved".utf8), ink = Data([1, 2, 3])
            try pdf.write(to: disk.pdfURL(for: invalid.scores[0].id))
            try disk.writeInk(ink, scoreID: invalid.scores[0].id, page: 0)
            XCTAssertThrowsError(try disk.load(), name) { error in
                guard case LibraryError.corruptIndex = error else { return XCTFail("\(name): \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), original, name)
            XCTAssertEqual(try Data(contentsOf: disk.pdfURL(for: invalid.scores[0].id)), pdf, name)
            XCTAssertEqual(try disk.readInk(scoreID: invalid.scores[0].id, page: 0), ink, name)
            XCTAssertFalse(disk.recoveredFromBackup, name)
        }
    }
    func testSemanticCorruptionRecoversValidBackupAndKeepsOriginalEvidence() throws {
        let disk = try disk(), valid = fixture()
        let backup = try write(valid, to: disk, backup: true)
        var invalid = valid; invalid.scores[0].lastPage = Int.max
        let original = try write(invalid, to: disk)
        XCTAssertEqual(try disk.load(), valid)
        XCTAssertTrue(disk.recoveredFromBackup)
        let evidence = try FileManager.default.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-damaged-") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(evidence.first)), original)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), original)
        try disk.save(valid)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json")), backup,
                       "Saving recovery must never promote a damaged primary into the backup")
        XCTAssertEqual(try disk.load(), valid)
        XCTAssertFalse(disk.recoveredFromBackup, "A successful primary read clears an earlier recovery flag")
    }
    func testInvalidBackupIsRejectedWhetherPrimaryIsMissingOrDamaged() throws {
        for missingPrimary in [true, false] {
            let disk = try disk(); var invalid = fixture(); invalid.scores[0].layouts[1]!.divider = 1e100
            let backup = try write(invalid, to: disk, backup: true)
            if !missingPrimary { try Data("broken".utf8).write(to: disk.root.appendingPathComponent("library.json")) }
            XCTAssertThrowsError(try disk.load()) { error in
                guard case LibraryError.corruptIndex = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json")), backup)
            XCTAssertFalse(disk.recoveredFromBackup)
        }
    }
    func testRejectedSaveDoesNotChangePrimaryOrBackup() throws {
        let disk = try disk(), valid = fixture(); try disk.save(valid)
        var newer = valid; newer.scores[0].title = "New title"; try disk.save(newer)
        let primary = try Data(contentsOf: disk.root.appendingPathComponent("library.json"))
        let backup = try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json"))
        for (name, invalid) in corruptVariants() {
            XCTAssertThrowsError(try disk.save(invalid), name)
            XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), primary, name)
            XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json")), backup, name)
        }
        var future = valid; future.version = 999
        XCTAssertThrowsError(try disk.save(future)) { error in
            guard case LibraryError.unsupportedVersion = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), primary)
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.backup.json")), backup)
    }
    func testRejectedFirstSaveCreatesNoIndexFiles() throws {
        let disk = try disk(); var invalid = fixture(); invalid.scores[0].lastPage = Int.max
        XCTAssertThrowsError(try disk.save(invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.root.appendingPathComponent("library.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.root.appendingPathComponent("library.backup.json").path))
    }
    func testNonFiniteRuntimeValuesCannotBeSaved() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            let disk = try disk(); var invalid = fixture(); invalid.scores[0].layouts[1]!.divider = value
            XCTAssertThrowsError(try disk.save(invalid)) { error in
                guard case LibraryError.corruptIndex = error else { return XCTFail("Validation must happen before encoding: \(error)") }
            }
        }
    }
    func testValidLegacyIndexStillLoadsWithOptionalDefaults() throws {
        let disk = try disk(), score = Score(title: "Legacy", pageCount: 4)
        var library = LibraryIndex(); library.scores = [score]
        let encoded = try JSONEncoder().encode(library)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var scores = try XCTUnwrap(object["scores"] as? [[String: Any]])
        for key in ["lastPage", "lastOpenedAt", "layouts", "viewports", "bookmarks", "composer", "part", "tags"] { scores[0].removeValue(forKey: key) }
        object["scores"] = scores
        try JSONSerialization.data(withJSONObject: object).write(to: disk.root.appendingPathComponent("library.json"))
        XCTAssertEqual(try disk.load(), library)
    }
    func testLibraryPageDisplayDoesNotOverflowTransientInvalidValues() {
        var score = Score(title: "Page display", pageCount: 4)
        score.lastPage = Int.max; XCTAssertEqual(score.lastPageNumber, 4)
        score.lastPage = Int.min; XCTAssertEqual(score.lastPageNumber, 1)
        score.lastPage = 2; XCTAssertEqual(score.lastPageNumber, 3)
        score.pageCount = 0; XCTAssertEqual(score.lastPageNumber, 1)
        score.pageCount = Int.min; XCTAssertEqual(score.lastPageNumber, 1)
        score.pageCount = Int.max; score.lastPage = Int.max
        XCTAssertEqual(score.lastPageNumber, Int.max)
    }
    func testPortableBackupAlsoRejectsDuplicateEntryIdentity() throws {
        let disk = try disk(); var invalid = fixture()
        invalid.setlists[0].entries.append(invalid.setlists[0].entries[0])
        try Data("%PDF-test".utf8).write(to: disk.pdfURL(for: invalid.scores[0].id))
        let archive = disk.root.appendingPathComponent("invalid.percuscorebackup")
        XCTAssertThrowsError(try LibraryBackup.export(index: invalid, disk: disk, to: archive)) { error in
            guard case BackupError.invalid = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }
    func testLegacyItemConvertedToPageKeepsItsInertSetlistReference() throws {
        let disk = try disk(); var legacy = fixture()
        // Earlier app versions allowed this edit without removing the old setlist entry.
        legacy.scores[0].bookmarks[0].endPage = nil
        let original = try write(legacy, to: disk)
        XCTAssertEqual(try? disk.load(), legacy)
        XCTAssertNil(legacy.resolve(legacy.setlists[0].entries[0]), "A page bookmark must never become a reading item")
        XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent("library.json")), original)
        try BackupTestAssets.writePDF(to: disk.pdfURL(for: legacy.scores[0].id), pages: 4)
        let archive = disk.root.appendingPathComponent("legacy.percuscorebackup")
        XCTAssertNoThrow(try LibraryBackup.export(index: legacy, disk: disk, to: archive))
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        let target = try self.disk()
        let restored = try LibraryBackup.restore(from: archive, disk: target, current: LibraryIndex())
        XCTAssertFalse(restored.scores[0].bookmarks[0].isItem)
        XCTAssertEqual(restored.setlists[0].entries[0].bookmarkID, restored.scores[0].bookmarks[0].id)
        XCTAssertNil(restored.resolve(restored.setlists[0].entries[0]))
    }
}
