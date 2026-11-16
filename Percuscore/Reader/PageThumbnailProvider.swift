import PDFKit
import UIKit

/// Owns a separate PDF document; thumbnail work never uses the reader's live PDFPage.
actor PageThumbnailProvider {
    private let url: URL
    private var document: PDFDocument?
    private let cache = NSCache<NSNumber, UIImage>()

    init(url: URL) {
        self.url = url
        cache.countLimit = 36
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func image(for page: Int) -> UIImage? {
        guard !Task.isCancelled, page >= 0 else { return nil }
        if let cached = cache.object(forKey: NSNumber(value: page)) { return cached }
        if document == nil { document = PDFDocument(url: url) }
        guard let document, !document.isLocked, let source = document.page(at: page) else { return nil }
        let image = source.thumbnail(of: CGSize(width: 240, height: 340), for: .mediaBox)
        guard !Task.isCancelled else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: NSNumber(value: page), cost: cost)
        return image
    }
}
