import UIKit

/// Original, generated practice material. No third-party score assets are bundled.
enum SampleScore {
    static func write(to url: URL) throws {
        let rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: rect)
        try renderer.writePDF(to: url) { context in
            for page in 0..<4 {
                context.beginPage()
                text("PERCUSCORE  /  ORIGINAL PRACTICE MATERIAL", x: 52, y: 34, size: 9)
                text(page == 0 ? "First rehearsal" : "First rehearsal · continued", x: 52, y: 66, size: 28, bold: true)
                text(["I. Pulse & space", "II. Accents", "III. Changing hands", "IV. Quiet control"][page],
                     x: 52, y: 106, size: 14)
                text("Snare drum     ♩ = 80", x: 52, y: 136, size: 12)
                let cg = context.cgContext
                cg.setStrokeColor(UIColor.black.cgColor); cg.setFillColor(UIColor.black.cgColor)
                for system in 0..<6 {
                    let y = CGFloat(200 + system * 82)
                    cg.setLineWidth(0.6)
                    for line in 0..<5 {
                        cg.move(to: CGPoint(x: 52, y: y + CGFloat(line * 5)))
                        cg.addLine(to: CGPoint(x: 560, y: y + CGFloat(line * 5)))
                    }
                    for bar in 0...4 {
                        let x = CGFloat(52 + bar * 127)
                        cg.move(to: CGPoint(x: x, y: y)); cg.addLine(to: CGPoint(x: x, y: y + 20))
                    }
                    cg.strokePath()
                    text("\(page * 24 + system * 4 + 1)", x: 37, y: y - 7, size: 9)
                    for note in 0..<16 {
                        let x = CGFloat(69 + note * 31)
                        cg.fillEllipse(in: CGRect(x: x, y: y + 7, width: 9, height: 6))
                        cg.setLineWidth(1)
                        cg.move(to: CGPoint(x: x + 8, y: y + 10)); cg.addLine(to: CGPoint(x: x + 8, y: y - 18)); cg.strokePath()
                        if (note + page) % 4 == 0 { text(">", x: x, y: y - 35, size: 14, bold: true) }
                        text(note % 2 == 0 ? "R" : "L", x: x, y: y + 28, size: 9)
                    }
                    if system == 0 { text(page % 2 == 0 ? "mf" : "p", x: 55, y: y + 40, size: 13, bold: true) }
                }
                text("A practice page for exploring crop, Pencil, bookmarks and page turns.", x: 52, y: 735, size: 9)
                text("\(page + 1)", x: 553, y: 758, size: 11)
            }
        }
    }
    private static func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        string.draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: UIColor.black])
    }
}
