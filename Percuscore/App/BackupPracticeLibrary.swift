import Foundation
import PencilKit
import UIKit

enum BackupPracticeLibrary {
    static func build(at root: URL) throws {
        let disk = try LibraryDisk(root: root)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path) else { throw CocoaError(.fileWriteFileExists) }
        var first = Score(title: "Backup practice · Colors and draft", pageCount: 4)
        var second = Score(title: "Backup practice · Crops and references", pageCount: 4)
        for i in 0..<2 {
            let id = i == 0 ? first.id : second.id
            try SampleScore.write(to: disk.pdfURL(for: id))
        }
        first.composer = "Percuscore practice"; first.part = "Percussion"; first.tags = ["Backup test"]; first.isFavorite = true
        first.lastPage = 2; second.lastPage = 1
        first.bookmarks = [.init(title: "Entry A", startPage: 0), .init(title: "Rehearsal passage", startPage: 1, endPage: 3)]
        second.bookmarks = [.init(title: "Second cue", startPage: 2), .init(title: "Closing phrase", startPage: 2, endPage: 3)]
        var crop = PageLayout(); crop.scale = 1.2; crop.offsetX = 0.03; crop.offsetY = -0.02; crop.rotation = 2; crop.divider = 0.4
        first.layouts[0] = crop
        crop.scale = 1.35; crop.rotation = -1; first.layouts[2] = crop; second.layouts[1] = crop
        var view = PageViewport(); view.scale = 1.75; view.offsetX = 0.15; view.offsetY = -0.1
        first.viewports[0] = view; view.scale = 2; view.offsetY = 0.2; second.viewports[1] = view
        let red = stroke(.red, y: 250), blue = stroke(.blue, y: 350), green = stroke(.green, y: 450)
        try disk.writeInk(PKDrawing(strokes: [red, blue]).dataRepresentation(), scoreID: first.id, page: 0)
        try disk.writeInk(PKDrawing(strokes: [green]).dataRepresentation(), scoreID: first.id, page: 2)
        try disk.writeInk(PKDrawing(strokes: [green]).dataRepresentation(), scoreID: second.id, page: 1)
        try disk.writeInk(PKDrawing(strokes: [red, blue, stroke(.purple, y: 550)]).dataRepresentation(), scoreID: first.id, page: 0, draft: true)
        var list = ScoreSetlist(title: "Backup practice · Repeated references")
        list.entries = [.init(scoreID: first.id), .init(scoreID: second.id, bookmarkID: second.bookmarks[1].id),
                        .init(scoreID: first.id, bookmarkID: first.bookmarks[1].id), .init(scoreID: second.id),
                        .init(scoreID: first.id, bookmarkID: first.bookmarks[1].id)]
        var index = LibraryIndex(); index.scores = [first, second]; index.setlists = [list]
        index.settings.halfPageTurns = true
        try disk.save(index)
    }
    private static func stroke(_ color: UIColor, y: CGFloat) -> PKStroke {
        let points = [CGPoint(x: 150, y: y), CGPoint(x: 600, y: y + 20)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i), size: CGSize(width: 7, height: 7), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }
}
