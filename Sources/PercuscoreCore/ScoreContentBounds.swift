import Foundation
import CoreGraphics

/// Detects visible ink in a white-backed, top-to-bottom RGBA thumbnail.
public enum ScoreContentBounds {
    public static let wholePage = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func detect(rgba: [UInt8], width: Int, height: Int) -> CGRect {
        guard width > 0, height > 0, width <= Int.max / 4 / height,
              rgba.count >= width * height * 4 else { return wholePage }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // Any colored channel counts: yellow highlights and light pencil matter too.
                if min(rgba[i], rgba[i + 1], rgba[i + 2]) < 248 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return wholePage }
        let padX = max(2, Int(ceil(Double(width) * 0.012)))
        let padY = max(2, Int(ceil(Double(height) * 0.012)))
        let left = max(0, minX - padX), top = max(0, minY - padY)
        let right = min(width, maxX + 1 + padX), bottom = min(height, maxY + 1 + padY)
        return CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height),
                      width: Double(right - left) / Double(width), height: Double(bottom - top) / Double(height))
    }

    /// Small bounded bitmap; the reader still displays its sharp original PDF and editable ink.
    public static func detect(image: CGImage) -> CGRect {
        let ratio = min(1, 1000.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio))
        let height = max(1, Int(Double(image.height) * ratio))
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? detect(rgba: rgba, width: width, height: height) : wholePage
    }
}
