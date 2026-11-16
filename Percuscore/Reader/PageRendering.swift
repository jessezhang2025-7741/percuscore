import UIKit
import PDFKit
import PencilKit

enum PageRendering {
    /// A temporary whole-page underlay, bounded independently of sharp PDF tiles.
    static func paperPreview(page: PDFPage) -> UIImage? {
        let size = size(of: page)
        guard let initial = previewPixelSize(for: size) else { return nil }
        let scale = min(1, sqrt(1_048_576 / initial.width / initial.height))
        let pixels = CGSize(width: max(1, floor(initial.width * scale)), height: max(1, floor(initial.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: pixels, format: format).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: pixels.width / size.width, y: pixels.height / size.height)
            drawPDF(page, in: context, rect: CGRect(origin: .zero, size: size))
        }
    }
    /// Ink always uses a fixed 1000-point page width, never view/screen coordinates.
    static func size(of page: PDFPage) -> CGSize {
        let box = page.pageRef?.getBoxRect(.mediaBox) ?? page.bounds(for: .mediaBox)
        let rotated = abs(page.rotation) % 180 == 90
        let width = rotated ? box.height : box.width
        let height = rotated ? box.width : box.height
        return CGSize(width: 1000, height: 1000 * height / max(1, width))
    }
    static func drawPDF(_ page: PDFPage, in context: CGContext, rect: CGRect) {
        guard let reference = page.pageRef else { return }
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor); context.fill(rect)
        context.translateBy(x: 0, y: rect.height); context.scaleBy(x: 1, y: -1)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        // Preserve annotations already embedded in imported PDFs as part of the base score.
        for annotation in page.annotations where annotation.shouldDisplay {
            annotation.draw(with: .mediaBox, in: context)
        }
        context.restoreGState()
    }
    static func cropTransform(_ layout: PageLayout, size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width / 2 + size.width * layout.offsetX,
                          y: size.height / 2 + size.height * layout.offsetY)
            .rotated(by: layout.rotation * .pi / 180)
            .scaledBy(x: layout.scale, y: layout.scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }
    /// Bound allocations before creating either the page bitmap or the ink bitmap.
    /// Canonical page/Pencil coordinates stay unchanged; only preview pixels shrink.
    static func previewPixelSize(for size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let maximumEdge: CGFloat = 4096
        let maximumPixels: CGFloat = 4_194_304
        // Divide before taking roots so extreme (but finite) dimensions cannot overflow an area calculation.
        let scale = min(1.5, maximumEdge / size.width, maximumEdge / size.height,
                        sqrt(maximumPixels / size.width) / sqrt(size.height))
        guard scale.isFinite, scale > 0 else { return nil }
        let pixels = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        guard pixels.width <= maximumEdge, pixels.height <= maximumEdge,
              pixels.width * pixels.height <= maximumPixels,
              (pixels.width / size.width).isFinite, (pixels.height / size.height).isFinite else { return nil }
        return pixels
    }

    static func image(page: PDFPage, drawing: PKDrawing, layout: PageLayout) -> UIImage {
        let size = size(of: page)
        let pixels = previewPixelSize(for: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return autoreleasepool {
            UIGraphicsImageRenderer(size: pixels ?? CGSize(width: 1, height: 1), format: format).image { renderer in
                let cg = renderer.cgContext
                UIColor.white.setFill(); cg.fill(CGRect(origin: .zero, size: pixels ?? CGSize(width: 1, height: 1)))
                // Invalid geometry must never reach UIKit/PencilKit allocation or transform code.
                guard let pixels else { return }
                let xScale = pixels.width / size.width, yScale = pixels.height / size.height
                cg.scaleBy(x: xScale, y: yScale)
                cg.saveGState(); cg.concatenate(cropTransform(layout, size: size))
                drawPDF(page, in: cg, rect: CGRect(origin: .zero, size: size))
                if !drawing.strokes.isEmpty {
                    let inkScale = min(xScale, yScale)
                    // Extremely thin pages still need at least one pixel in each ink dimension.
                    // Expanding this transparent rect preserves coordinates and avoids a zero-pixel allocation.
                    let inkRect = CGRect(x: 0, y: 0, width: max(size.width, 1 / inkScale),
                                         height: max(size.height, 1 / inkScale))
                    drawing.image(from: inkRect, scale: inkScale).draw(in: inkRect)
                }
                cg.restoreGState()
            }
        }
    }

    /// Half-page previews use the same content crop as the vector PDF viewport.
    static func trimmedImage(_ image: UIImage?, to bounds: CGRect) -> UIImage? {
        guard let image, let source = image.cgImage else { return image }
        let pixels = CGRect(x: bounds.minX * CGFloat(source.width), y: bounds.minY * CGFloat(source.height),
                            width: bounds.width * CGFloat(source.width), height: bounds.height * CGFloat(source.height)).integral
        guard let cropped = source.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}

final class ImmediatePDFTileLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

final class PDFPaperView: UIView {
    let page: PDFPage
    private let document: PDFDocument?
    private let drawingRect: CGRect
    override class var layerClass: AnyClass { ImmediatePDFTileLayer.self }
    init(page: PDFPage) {
        self.page = page; document = page.document
        drawingRect = CGRect(origin: .zero, size: PageRendering.size(of: page))
        super.init(frame: drawingRect)
        // Missing tiles reveal this SAME page's preview below, never a previous page.
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
        if let layer = layer as? CATiledLayer {
            layer.levelsOfDetail = 1; layer.levelsOfDetailBias = 4
            layer.tileSize = CGSize(width: 1024, height: 1024)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // Immutable page/geometry snapshots; CATiledLayer invokes drawing off-main.
        PageRendering.drawPDF(page, in: context, rect: drawingRect)
    }
}
