import XCTest
import CoreGraphics
@testable import PercuscoreCore

final class ScoreContentBoundsTests: XCTestCase {
    private func image(width: Int = 100, height: Int = 100, pixels: [(Int, Int, [UInt8])]) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for (x, y, color) in pixels {
            let index = (y * width + x) * 4
            for channel in 0..<3 { rgba[index + channel] = color[channel] }
        }
        return rgba
    }

    func testRemovesLargeWhiteMarginsButKeepsPaddingAroundMusic() {
        let rgba = image(pixels: [(20, 30, [0, 0, 0]), (79, 69, [0, 0, 0])])
        let rect = ScoreContentBounds.detect(rgba: rgba, width: 100, height: 100)
        XCTAssertTrue(rect.minX > 0.1 && rect.minX < 0.2)
        XCTAssertTrue(rect.minY > 0.2 && rect.minY < 0.3)
        XCTAssertTrue(rect.maxX > 0.8 && rect.maxX < 0.9)
        XCTAssertTrue(rect.maxY > 0.7 && rect.maxY < 0.8)
    }

    func testIncludesColoredAndFaintHandwritingOutsideTheStaves() {
        let rgba = image(pixels: [(20, 30, [0, 0, 0]), (79, 69, [0, 0, 0]),
                                  (8, 12, [255, 200, 200]), (92, 85, [244, 244, 244])])
        let rect = ScoreContentBounds.detect(rgba: rgba, width: 100, height: 100)
        XCTAssertTrue(rect.minX < 0.08 && rect.minY < 0.12)
        XCTAssertTrue(rect.maxX > 0.92 && rect.maxY > 0.85)
        XCTAssertTrue(rect.width < 1)
    }

    func testBlankAndInvalidImagesKeepWholePage() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(ScoreContentBounds.detect(rgba: image(pixels: []), width: 100, height: 100), unit)
        XCTAssertEqual(ScoreContentBounds.detect(rgba: [], width: 100, height: 100), unit)
        XCTAssertEqual(ScoreContentBounds.detect(rgba: [], width: 0, height: 0), unit)
    }

    func testMarksAtPaperEdgesAreNotCutOff() {
        let rgba = image(pixels: [(0, 0, [0, 0, 0]), (99, 99, [255, 255, 0])])
        XCTAssertEqual(ScoreContentBounds.detect(rgba: rgba, width: 100, height: 100),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testBitmapDetectionPreservesAsymmetricTopLeftCoordinates() throws {
        let rgba = image(pixels: [(12, 8, [255, 160, 160]), (79, 44, [0, 0, 0])])
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let bitmap = try XCTUnwrap(CGImage(width: 100, height: 100, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(ScoreContentBounds.detect(image: bitmap),
                       ScoreContentBounds.detect(rgba: rgba, width: 100, height: 100))
    }
}
