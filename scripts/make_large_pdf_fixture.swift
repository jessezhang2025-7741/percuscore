import Foundation
import CoreGraphics
import ImageIO
import CoreText
import UniformTypeIdentifiers

let args = CommandLine.arguments
func option(_ key: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }; return args[i + 1]
}
let path = option("--output", "/private/tmp/Percuscore-large-pdf/scanned.pdf")
let pages = Int(option("--pages", "120"))!, dpi = Int(option("--dpi", "300"))!
let seed = UInt64(option("--seed", "20260929"))!
precondition(pages > 0 && dpi > 0)
let width = Int(8.5 * Double(dpi)), height = 11 * dpi
let url = URL(fileURLWithPath: path)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
let start = Date()
for page in 0..<pages {
    autoreleasepool {
        let gray = page % 2 == 0, components = gray ? 1 : 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * components)
        defer { bytes.deallocate() }
        var random = seed &+ UInt64(page * 7919)
        for p in 0..<(width * height) {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let noise = UInt8((random >> 56) % 13)
            if gray { bytes[p] = 255 - noise }
            else {
                bytes[p * 4] = 255 - noise; bytes[p * 4 + 1] = 251 - noise
                bytes[p * 4 + 2] = 244 - noise; bytes[p * 4 + 3] = 255
            }
        }
        let bitmap = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * components, space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.scaleBy(x: CGFloat(width) / 612, y: CGFloat(height) / 792)
        bitmap.setStrokeColor(gray ? CGColor(gray: 0.1, alpha: 1) : CGColor(red: 0.13, green: 0.1, blue: 0.1, alpha: 1))
        bitmap.setFillColor(gray ? CGColor(gray: 0.1, alpha: 1) : CGColor(red: 0.13, green: 0.1, blue: 0.1, alpha: 1))
        bitmap.setLineWidth(0.7)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic percussion scan · Page \(page + 1)", attributes: [.init(kCTFontAttributeName as String): font]))
        bitmap.textPosition = CGPoint(x: 42, y: 742); CTLineDraw(line, bitmap)
        for row in 0..<11 {
            let y = CGFloat(680 - row * 54)
            for staff in 0..<5 {
                bitmap.move(to: CGPoint(x: 42, y: y + CGFloat(staff * 5)))
                bitmap.addLine(to: CGPoint(x: 570, y: y + CGFloat(staff * 5))); bitmap.strokePath()
            }
            for note in 0..<18 {
                let x = CGFloat(52 + note * 29), yy = y + CGFloat((note + page + row) % 5 * 5)
                bitmap.fillEllipse(in: CGRect(x: x, y: yy - 3, width: 9, height: 6))
                bitmap.move(to: CGPoint(x: x + 8, y: yy)); bitmap.addLine(to: CGPoint(x: x + 8, y: yy + 24)); bitmap.strokePath()
            }
        }
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let image = CGImage(jpegDataProviderSource: CGDataProvider(data: encoded)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        pdf.beginPDFPage(nil); pdf.draw(image, in: box); pdf.endPDFPage()
    }
}
pdf.closePDF()
let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
let metadata: [String: Any] = ["path": path, "pages": pages, "dpi": dpi, "width": width, "height": height,
    "image_mode": "alternating grayscale/RGB", "compression": "JPEG 0.76", "bytes": size,
    "seed": seed, "generation_seconds": Date().timeIntervalSince(start)]
print(String(data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), encoding: .utf8)!)
