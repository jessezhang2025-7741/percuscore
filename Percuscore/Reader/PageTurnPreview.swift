import UIKit
import PDFKit

struct PaperPreviewKey: Hashable, Sendable {
    let scoreID: UUID
    let page: Int
}

struct PaperPreviewRequest: Sendable {
    let key: PaperPreviewKey
    let url: URL
}

/// Immutable pixels only. Pencil ink and page/view transforms stay in the live canvas.
final class PaperPreview: @unchecked Sendable {
    let image: UIImage
    let canonicalSize: CGSize
    var bytes: Int { image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }

    init(image: UIImage, canonicalSize: CGSize) {
        self.image = image
        self.canonicalSize = canonicalSize
    }
}

protocol PaperPreviewRendering: Sendable {
    func render(_ request: PaperPreviewRequest) async throws -> PaperPreview?
}

private actor PaperPreviewRenderer: PaperPreviewRendering {
    func render(_ request: PaperPreviewRequest) async throws -> PaperPreview? {
        try Task.checkCancellation()
        // Release each independent document after drawing; do not accumulate a
        // second PDFKit resource cache while reading a long scanned score.
        let result = autoreleasepool { () -> PaperPreview? in
            guard let document = PDFDocument(url: request.url), !document.isLocked,
                  let page = document.page(at: request.key.page),
                  let image = PageRendering.paperPreview(page: page) else { return nil }
            return withExtendedLifetime(document) {
                PaperPreview(image: image, canonicalSize: PageRendering.size(of: page))
            }
        }
        try Task.checkCancellation()
        return result
    }
}

/// Strictly bounded decoded-image ownership, one render in flight, latest wanted queue.
@MainActor
final class PageTurnPreviewCache {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumCount = 3
    private let byteLimit: Int
    private let countLimit: Int
    private let renderer: any PaperPreviewRendering
    private var images: [PaperPreviewKey: PaperPreview] = [:]
    private var order: [PaperPreviewKey] = []
    private var wanted: Set<PaperPreviewKey> = []
    private var pending: [PaperPreviewRequest] = []
    private var inFlight: (key: PaperPreviewKey, epoch: Int)?
    private var epoch = 0
    private var task: Task<Void, Never>?
    private(set) var retainedBytes = 0
    var count: Int { images.count }
    var onReady: ((PaperPreviewKey) -> Void)?

    init(byteLimit: Int = PageTurnPreviewCache.maximumBytes, countLimit: Int = PageTurnPreviewCache.maximumCount,
         renderer: (any PaperPreviewRendering)? = nil) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
        self.renderer = renderer ?? PaperPreviewRenderer()
    }

    deinit { task?.cancel() }

    func preview(for key: PaperPreviewKey) -> PaperPreview? {
        guard let image = images[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return image
    }

    func request(_ requests: [PaperPreviewRequest], retaining keys: Set<PaperPreviewKey>, delayNanoseconds: UInt64 = 20_000_000) {
        wanted = keys
        for key in Array(images.keys) where !keys.contains(key) { remove(key) }
        var seen: Set<PaperPreviewKey> = []
        pending = requests.filter { request in
            let sameLiveRequest = request.key == inFlight?.key && inFlight?.epoch == epoch
            return keys.contains(request.key) && images[request.key] == nil && !sameLiveRequest && seen.insert(request.key).inserted
        }.prefix(2).map { $0 }
        startIfNeeded(delayNanoseconds: delayNanoseconds)
    }

    func removeAll() {
        epoch += 1
        wanted.removeAll(); pending.removeAll(); images.removeAll(); order.removeAll(); retainedBytes = 0
        // A Core Graphics draw already in progress finishes safely; its old epoch is rejected.
    }

    private func remove(_ key: PaperPreviewKey) {
        if let removed = images.removeValue(forKey: key) { retainedBytes -= removed.bytes }
        order.removeAll { $0 == key }
    }

    private func insert(_ preview: PaperPreview, for key: PaperPreviewKey) {
        guard preview.bytes > 0, preview.bytes <= byteLimit, countLimit > 0 else { return }
        remove(key)
        while images.count >= countLimit || retainedBytes + preview.bytes > byteLimit {
            guard let oldest = order.first else { return }
            remove(oldest)
        }
        images[key] = preview; order.append(key); retainedBytes += preview.bytes
    }

    private func startIfNeeded(delayNanoseconds: UInt64) {
        guard task == nil, !pending.isEmpty else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delayNanoseconds) } catch { return }
            await self?.drain()
        }
    }

    private func drain() async {
        defer { task = nil; startIfNeeded(delayNanoseconds: 0) }
        while !Task.isCancelled, !pending.isEmpty {
            let request = pending.removeFirst()
            guard wanted.contains(request.key), images[request.key] == nil else { continue }
            let version = epoch
            inFlight = (request.key, version)
            let result = try? await renderer.render(request)
            inFlight = nil
            guard !Task.isCancelled, epoch == version, wanted.contains(request.key), let result else { continue }
            insert(result, for: request.key)
            if images[request.key] != nil { onReady?(request.key) }
        }
    }
}
