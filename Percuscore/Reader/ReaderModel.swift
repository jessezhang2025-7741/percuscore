import SwiftUI
import PDFKit
import PencilKit

enum ReaderMode { case reading, annotating, cropping }

struct NavigationFailure {
    let target: ReadingSession
    let forward: Bool
    let canIgnoreMarkings: Bool
    let resumeAnnotation: Bool
    let message: String
}

private enum PagePreparationError: Error {
    case markings(Error)
}

private struct PreparedReaderPage {
    let document: PDFDocument
    let page: PDFPage
    let drawing: PKDrawing
    let recoveryData: Data?
    let layout: PageLayout
    let viewport: PageViewport
    let ignoringMarkings: Bool
}

/// Keep display geometry separate from the bounded raster's rounded pixel dimensions.
private final class PagePreview: NSObject, @unchecked Sendable {
    let image: UIImage
    let canonicalSize: CGSize
    init(image: UIImage, canonicalSize: CGSize) {
        self.image = image
        // Rejected geometry renders a white pixel and must not enter UIView layout either.
        self.canonicalSize = PageRendering.previewPixelSize(for: canonicalSize) == nil
            ? CGSize(width: 1, height: 1) : canonicalSize
    }
}

/// Pencil-only drawing policy still permits finger smart-selection gestures.
/// Route reading touches past the ink layer before PencilKit sees them.
@MainActor
final class ReaderCanvasView: PKCanvasView {
    var allowsEditing = false

    func acceptsInput(at point: CGPoint, contacts: [(type: UITouch.TouchType, location: CGPoint)]) -> Bool {
        guard isUserInteractionEnabled else { return false }
        if allowsEditing { return true }
        guard drawingGestureRecognizer.isEnabled else { return false }
        // allTouches also includes fingers elsewhere on the screen. Only the
        // Pencil contact at this hit-test point may enter the reading canvas.
        return contacts.contains {
            $0.type == .pencil && abs($0.location.x - point.x) < 1 && abs($0.location.y - point.y) < 1
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let contacts = event?.allTouches?.map { (type: $0.type, location: $0.location(in: self)) } ?? []
        guard acceptsInput(at: point, contacts: contacts) else { return nil }
        return super.hitTest(point, with: event)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard allowsEditing else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

@MainActor
final class ReaderModel: NSObject, ObservableObject, PKCanvasViewDelegate {
    let store: LibraryStore
    private let diagnostics: ReaderDiagnostics
    private(set) var canvas = ReaderCanvasView()
    @Published var session: ReadingSession
    @Published var mode: ReaderMode = .reading {
        didSet {
            if mode != oldValue, let state = ReaderDiagnosticEvent.State(rawValue: String(describing: mode)) {
                recordDiagnostic(.modeChanged, state: state)
            }
        }
    }
    @Published var controlsVisible = true
    @Published var performance = PerformanceSession()
    @Published var layout = PageLayout()
    @Published var viewport = PageViewport()
    @Published var inkVisible = true
    @Published var isLandscape = false
    @Published var zoomed = false
    @Published var revision = 0
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var recoveryAvailable = false
    @Published var errorMessage: String?
    @Published private(set) var saveActivity = SaveActivity()
    var saveState: SaveState { saveActivity.state }
    @Published private(set) var page: PDFPage?
    @Published private(set) var navigationFailure: NavigationFailure?
    @Published private(set) var ignoringMarkings = false
    private var ignoredMarkingPages: Set<String> = []
    private var loadedSession: ReadingSession?
    // Retain readable paper even when a target preload evicts the document cache.
    private var loadedDocument: PDFDocument?
    private var documents: [UUID: PDFDocument] = [:]
    private var baseline = PKDrawing()
    private var undoFrames: [Data] = []
    private var redoFrames: [Data] = []
    private var gestureBaseline: Data?
    private var strokeStartedAt: TimeInterval?
    private var observedStrokeChange = false
    private var loadingDrawing = false
    private var draftTask: Task<Void, Never>?
    private var committedLayout = PageLayout()
    private var recoveryData: Data?
    private let renderedPages = NSCache<NSString, PagePreview>()
    // The two active half-page images must survive advisory cache eviction.
    private var activePreviews: [NSString: PagePreview] = [:]
    private var prefetchTask: Task<Void, Never>?
    private let renderWorker = ReaderRenderWorker()
    private let paperPreviews = PageTurnPreviewCache()
    private var paperPreviewPaused = false
    private var paperPreviewActive = true
    private var paperPreviewForward = true
    private var hasNavigated = false
    private var readingProgress = ReadingProgressBuffer()
    private var progressSaveTask: Task<Void, Never>?
    var settings: ReaderSettings { store.index.settings }
    var scoreID: UUID { session.item.scoreID }
    var pageIndex: Int { session.position.page }
    var currentScore: Score? { store.score(scoreID) }
    var landscapeSteps: Bool { isLandscape && settings.landscapeSteps }
    var allowsHalfTurn: Bool { settings.halfPageTurns && !isLandscape && mode == .reading }

    func recordDiagnostic(_ kind: ReaderDiagnosticEvent.Kind, state: ReaderDiagnosticEvent.State, durationMS: Double? = nil) {
        diagnostics.record(kind, state: state, page: pageIndex + 1,
                                        item: session.position.itemIndex, durationMS: durationMS)
    }
    func flushDiagnostics() { diagnostics.flush() }

    init(store: LibraryStore, session: ReadingSession, diagnostics: ReaderDiagnostics? = nil) {
        self.store = store; self.session = session; self.diagnostics = diagnostics ?? .shared
        super.init()
        paperPreviews.onReady = { [weak self] key in
            guard let self, key == self.currentPaperPreviewKey, self.allowsPaperPreview else { return }
            self.revision += 1
        }
        renderedPages.countLimit = 4
        renderedPages.totalCostLimit = 48 * 1024 * 1024
        NotificationCenter.default.addObserver(self, selector: #selector(releasePreviewMemory),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        loadCurrentPage()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        prefetchTask?.cancel()
        draftTask?.cancel()
        progressSaveTask?.cancel()
    }

    private func replaceCanvas(with drawing: PKDrawing) {
        // PencilKit can finish rendering/tool callbacks after a page turn. A view
        // belongs to one page only, so its queued work cannot mutate the next page.
        canvas.delegate = nil
        canvas.isUserInteractionEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = false
        let replacement = ReaderCanvasView()
        replacement.backgroundColor = .clear; replacement.isOpaque = false
        replacement.isScrollEnabled = false
        replacement.contentInsetAdjustmentBehavior = .never
        replacement.contentInset = .zero
        replacement.minimumZoomScale = 1; replacement.maximumZoomScale = 1
        replacement.tool = canvas.tool
        replacement.drawing = drawing
        canvas = replacement
        replacement.delegate = self
    }

    func enterPerformance() {
        guard page != nil, mode == .reading, !recoveryAvailable, !store.isImporting else { return }
        rememberViewport()
        performance.enter()
        controlsVisible = false
        configureCanvas()
        revision += 1
    }
    func exitPerformance() {
        rememberViewport()
        performance.exit()
        controlsVisible = true
        configureCanvas()
        revision += 1
    }

    func document(_ id: UUID) throws -> PDFDocument {
        if let cached = documents[id] { return cached }
        guard let url = store.fileURL(id), let document = PDFDocument(url: url), !document.isLocked else {
            throw LibraryError.missingFile
        }
        // Only retain the current and neighboring documents, not a whole concert in memory.
        if documents.count >= 3 { documents.removeAll() }
        documents[id] = document
        return document
    }
    private func markingKey(_ target: ReadingSession) -> String {
        "\(target.item.scoreID)-\(target.position.page)"
    }

    /// No reader state changes, writes, or draft cleanup until every target asset is ready.
    private func preparePage(_ target: ReadingSession, ignoreMarkings: Bool = false) throws -> PreparedReaderPage {
        let id = target.item.scoreID, index = target.position.page
        let document = try document(id)
        guard let pdfPage = document.page(at: index), let disk = store.disk else { throw LibraryError.missingFile }
        let ignored = ignoreMarkings || ignoredMarkingPages.contains(markingKey(target))
        var drawing = PKDrawing(), draft: Data?
        if !ignored {
            do {
                drawing = try disk.readInk(scoreID: id, page: index).map { try PKDrawing(data: $0) } ?? PKDrawing()
                draft = try disk.readInk(scoreID: id, page: index, draft: true)
                if let draft { _ = try PKDrawing(data: draft) }
            } catch { throw PagePreparationError.markings(error) }
        }
        let score = store.score(id)
        var viewport = readingProgress.viewport(scoreID: id, page: index) ?? score?.viewports[index] ?? PageViewport()
        viewport.normalize()
        return PreparedReaderPage(document: document, page: pdfPage, drawing: drawing, recoveryData: draft,
                                  layout: score?.layouts[index] ?? PageLayout(), viewport: viewport, ignoringMarkings: ignored)
    }

    private func applyPage(_ prepared: PreparedReaderPage, session target: ReadingSession) {
        draftTask?.cancel(); draftTask = nil; gestureBaseline = nil
        session = target; loadedSession = target; loadedDocument = prepared.document
        baseline = prepared.drawing; replaceCanvas(with: prepared.drawing)
        undoFrames = []; redoFrames = []; updateHistory()
        layout = prepared.layout; committedLayout = layout
        viewport = prepared.viewport; zoomed = viewport.scale > 1.02
        recoveryData = prepared.recoveryData; recoveryAvailable = recoveryData != nil
        ignoringMarkings = prepared.ignoringMarkings
        page = prepared.page
        if recoveryAvailable || ignoringMarkings { mode = .reading }
        if recoveryAvailable { performance.exit(); controlsVisible = true }
        clearNavigationFailure()
        revision += 1; configureCanvas()
        readingProgress.record(scoreID: scoreID, page: pageIndex); scheduleProgressSave(); prefetchPages()
        if !ignoringMarkings { _ = cleanupCommittedDraft() }
    }

    private func failedNavigation(_ error: Error, target: ReadingSession, forward: Bool, resumeAnnotation: Bool) {
        let detail: String, canIgnore: Bool
        if case PagePreparationError.markings(let underlying) = error {
            detail = underlying.localizedDescription; canIgnore = true
        } else { detail = error.localizedDescription; canIgnore = false }
        let message = "Unable to open page \(target.position.page + 1) of \(target.item.title). \(detail) Your current page and files have been preserved."
        navigationFailure = NavigationFailure(target: target, forward: forward, canIgnoreMarkings: canIgnore,
                                              resumeAnnotation: resumeAnnotation, message: message)
        errorMessage = message
    }

    func clearNavigationFailure() {
        if let failure = navigationFailure, errorMessage == failure.message { errorMessage = nil }
        navigationFailure = nil
    }

    func loadCurrentPage() {
        let target = session
        let start = ProcessInfo.processInfo.systemUptime
        do {
            applyPage(try preparePage(target), session: target)
            recordDiagnostic(.pageLoaded, state: .succeeded, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        catch {
            // Also protect callers replacing a queue before requesting a load.
            if let loadedSession { session = loadedSession }
            failedNavigation(error, target: target, forward: true, resumeAnnotation: mode == .annotating)
            if page == nil { performance.exit(); controlsVisible = true }
            recordDiagnostic(.pageFailed, state: .failed, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
    }

    @discardableResult
    func openSession(_ target: ReadingSession) -> Bool {
        guard !store.isImporting, mode != .cropping, !recoveryAvailable,
              canvas.drawingGestureRecognizer.state != .began,
              canvas.drawingGestureRecognizer.state != .changed else { return false }
        return navigate(to: target, forward: true, resumeAnnotation: false)
    }

    @discardableResult
    private func navigate(to target: ReadingSession, forward: Bool, resumeAnnotation: Bool,
                          ignoreMarkings: Bool = false) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        paperPreviewForward = forward
        hasNavigated = true
        var completed = false
        defer {
            diagnostics.record(completed ? .pageLoaded : .pageFailed, state: completed ? .succeeded : .failed,
                page: target.position.page + 1, item: target.position.itemIndex,
                durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        // Same physical page: retain live ink/viewport. Reading the disk first would
        // replace edits with an older drawing after saving them on a same-page seek.
        if page != nil, target.item.scoreID == scoreID, target.position.page == pageIndex, !ignoreMarkings {
            clearNavigationFailure()
            guard prepareForPageChange() else { return false }
            session = target; loadedSession = target; clearNavigationFailure()
        } else {
            let prepared: PreparedReaderPage
            do { prepared = try preparePage(target, ignoreMarkings: ignoreMarkings) }
            catch { failedNavigation(error, target: target, forward: forward, resumeAnnotation: resumeAnnotation); return false }
            // Once the target is ready, any failure belongs to saving the outgoing
            // page. Let the save alert/Retry UI report it instead of a stale notice.
            clearNavigationFailure()
            guard page == nil || prepareForPageChange() else { return false }
            if ignoreMarkings { ignoredMarkingPages.insert(markingKey(target)) }
            applyPage(prepared, session: target)
        }
        paperPreviewPaused = false
        performance.pageTurned()
        if resumeAnnotation { beginAnnotation() }
        configureCanvas(); revision += 1; prefetchPages()
        completed = true
        return true
    }

    var canSkipFailedPage: Bool {
        guard let failure = navigationFailure else { return false }
        return (failure.forward ? failure.target.nextPosition(continueQueue: settings.continueSetlist)
                : failure.target.previousPosition(continueQueue: settings.continueSetlist)) != nil
    }

    @discardableResult
    func ignoreFailedMarkings() -> Bool {
        guard let failure = navigationFailure, failure.canIgnoreMarkings,
              !store.isImporting, mode != .cropping, !recoveryAvailable,
              canvas.drawingGestureRecognizer.state != .began,
              canvas.drawingGestureRecognizer.state != .changed else { return false }
        return navigate(to: failure.target, forward: failure.forward, resumeAnnotation: false, ignoreMarkings: true)
    }

    @discardableResult
    func skipFailedPage() -> Bool {
        guard let failure = navigationFailure, canSkipFailedPage,
              !store.isImporting, mode != .cropping, !recoveryAvailable,
              canvas.drawingGestureRecognizer.state != .began,
              canvas.drawingGestureRecognizer.state != .changed else { return false }
        var target = failure.target
        target.resetStages()
        if failure.forward { target.next(halfPage: false, landscape: false, continueQueue: settings.continueSetlist) }
        else { target.previous(halfPage: false, landscape: false, continueQueue: settings.continueSetlist) }
        target.resetStages()
        return navigate(to: target, forward: failure.forward, resumeAnnotation: failure.resumeAnnotation)
    }

    func configureCanvas() {
        updatePaperPreviewRequests()
        let active = !ignoringMarkings && !performance.isActive && page != nil && !store.isImporting && !session.showingTransition && !(landscapeSteps && mode == .reading) && mode != .cropping && !recoveryAvailable
        canvas.isHidden = !inkVisible
        canvas.drawingPolicy = (mode == .annotating && !settings.preventFingerDrawing) ? .anyInput : .pencilOnly
        canvas.allowsEditing = active && mode == .annotating
        canvas.isUserInteractionEnabled = active && (mode == .annotating || settings.pencilAutoAnnotate)
        canvas.drawingGestureRecognizer.isEnabled = active && (mode == .annotating || settings.pencilAutoAnnotate)
        canvas.isRulerActive = mode == .annotating && canvas.isRulerActive
        // PKToolPicker owns the selected tool; refreshing a page must not reset it.
    }

    func beginAnnotation() {
        guard !performance.isActive, !ignoringMarkings else { return }
        guard page != nil, !store.isImporting, mode != .cropping, !recoveryAvailable else { return }
        if mode != .annotating {
            session.resetStages(); baseline = canvas.drawing
            undoFrames = []; redoFrames = []; updateHistory()
            mode = .annotating; controlsVisible = true; inkVisible = true
            configureCanvas()
        }
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        beginAnnotation()
        guard mode == .annotating else { return }
        strokeStartedAt = ProcessInfo.processInfo.systemUptime; observedStrokeChange = false
        recordDiagnostic(.strokeBegan, state: .started)
        saveActivity.begin(.ink)
        gestureBaseline = canvas.drawing.dataRepresentation()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard canvasView === canvas, !loadingDrawing, mode == .annotating else { return }
        if let start = strokeStartedAt, !observedStrokeChange {
            observedStrokeChange = true
            recordDiagnostic(.strokeChanged, state: .succeeded, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        saveActivity.begin(.ink)
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flushDraft()
        }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        recordDiagnostic(.strokeEnded, state: .succeeded,
                         durationMS: strokeStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 })
        strokeStartedAt = nil
        if let previous = gestureBaseline, previous != canvas.drawing.dataRepresentation() {
            undoFrames.append(previous); redoFrames = []
            if undoFrames.count > 100 { undoFrames.removeFirst() }
        }
        gestureBaseline = nil; updateHistory(); flushDraft()
    }
    func flushDraft() {
        rememberViewport()
        flushReadingProgress()
        draftTask?.cancel(); draftTask = nil
        guard mode == .annotating else { return }
        let start = ProcessInfo.processInfo.systemUptime
        var saved = false
        defer { recordDiagnostic(.saveDraft, state: saved ? .succeeded : .failed, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        saveActivity.begin(.ink)
        do {
            guard let disk = store.disk else { throw CocoaError(.fileWriteUnknown) }
            try disk.writeInk(canvas.drawing.dataRepresentation(), scoreID: scoreID, page: pageIndex, draft: true)
            saveActivity.finish(.ink)
            saved = true
        } catch {
            saveActivity.fail(.ink)
            errorMessage = "Ink could not be saved. Keep this page open and free some storage. \(error.localizedDescription)"
        }
    }
    @discardableResult
    func retrySaving() -> Bool {
        if saveActivity.hasFailure(.annotation), !saveAnnotation() { return false }
        if saveActivity.hasFailure(.draftCleanup), !cleanupCommittedDraft() { return false }
        if mode == .cropping { saveCrop() }
        else if saveActivity.hasFailure(.crop) { _ = persistLayout() }
        flushDraft()
        return saveState != .failed && saveState != .saving
    }
    @discardableResult
    func prepareForPageChange() -> Bool {
        guard mode != .cropping, !recoveryAvailable,
              canvas.drawingGestureRecognizer.state != .began,
              canvas.drawingGestureRecognizer.state != .changed else { return false }
        guard !saveActivity.hasFailure(.crop) || persistLayout() else { return false }
        guard !saveActivity.hasFailure(.draftCleanup) || cleanupCommittedDraft() else { return false }
        rememberViewport()
        return saveAnnotation()
    }
    @discardableResult
    func saveAnnotation() -> Bool {
        guard mode == .annotating else { return true }
        let start = ProcessInfo.processInfo.systemUptime
        var saved = false
        defer { recordDiagnostic(.saveAnnotation, state: saved ? .succeeded : .failed, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        draftTask?.cancel(); draftTask = nil
        saveActivity.begin(.annotation)
        let drawing = canvas.drawing
        do {
            guard let disk = store.disk else { throw LibraryError.missingFile }
            try disk.commitInk(drawing.dataRepresentation(), scoreID: scoreID, page: pageIndex)
        } catch { saveActivity.fail(.annotation); errorMessage = error.localizedDescription; return false }
        // The drawing is now confirmed on disk, regardless of the following cleanup result.
        saveActivity.finish(.annotation); saveActivity.finish(.ink)
        saved = true
        baseline = drawing; mode = .reading; undoFrames = []; redoFrames = []; gestureBaseline = nil
        updateHistory(); configureCanvas(); revision += 1
        renderedPages.removeAllObjects(); activePreviews.removeAll(); prefetchPages()
        return cleanupCommittedDraft()
    }
    @discardableResult
    private func cleanupCommittedDraft() -> Bool {
        let hadOnlyCleanupFailure = saveActivity.hasOnlyCleanupFailure
        saveActivity.begin(.draftCleanup)
        do {
            guard let disk = store.disk else { throw LibraryError.missingFile }
            if try disk.cleanupCommittedDraft(scoreID: scoreID, page: pageIndex) {
                saveActivity.finish(.draftCleanup)
                recordDiagnostic(.draftCleanup, state: .succeeded)
            } else { saveActivity.cancel(.draftCleanup) }
            if hadOnlyCleanupFailure { errorMessage = nil }
            return true
        } catch {
            saveActivity.fail(.draftCleanup)
            recordDiagnostic(.draftCleanup, state: .failed)
            errorMessage = "Markings saved, but an older recovery copy could not be removed. Retry cleanup. \(error.localizedDescription)"
            return false
        }
    }
    func cancelAnnotation() {
        guard !ignoringMarkings else { return }
        draftTask?.cancel(); draftTask = nil
        do {
            guard let disk = store.disk else { throw CocoaError(.fileWriteUnknown) }
            try disk.discardDraft(scoreID: scoreID, page: pageIndex)
        } catch { saveActivity.fail(.ink); errorMessage = error.localizedDescription; return }
        saveActivity.cancel(.ink); saveActivity.cancel(.annotation); saveActivity.cancel(.draftCleanup)
        setDrawing(baseline); mode = .reading; undoFrames = []; redoFrames = []
        updateHistory(); configureCanvas(); revision += 1
    }
    func recoverDraft() {
        do {
            guard let recoveryData else { return }
            let recovered = try PKDrawing(data: recoveryData)
            recoveryAvailable = false; beginAnnotation(); setDrawing(recovered)
            self.recoveryData = nil; revision += 1
            flushDraft()
        } catch { errorMessage = error.localizedDescription }
    }
    func discardRecovery() {
        guard !ignoringMarkings else { return }
        do {
            try store.disk?.discardDraft(scoreID: scoreID, page: pageIndex)
            recoveryData = nil; recoveryAvailable = false; configureCanvas()
        } catch { errorMessage = error.localizedDescription }
    }
    func undo() {
        guard let previous = undoFrames.last, let drawing = try? PKDrawing(data: previous) else { return }
        undoFrames.removeLast(); redoFrames.append(canvas.drawing.dataRepresentation())
        setDrawing(drawing); updateHistory(); flushDraft()
    }
    func redo() {
        guard let next = redoFrames.last, let drawing = try? PKDrawing(data: next) else { return }
        redoFrames.removeLast(); undoFrames.append(canvas.drawing.dataRepresentation())
        setDrawing(drawing); updateHistory(); flushDraft()
    }
    private func updateHistory() { canUndo = !undoFrames.isEmpty; canRedo = !redoFrames.isEmpty }
    private func setDrawing(_ drawing: PKDrawing) { loadingDrawing = true; canvas.drawing = drawing; loadingDrawing = false }

    func beginCrop() {
        guard !performance.isActive, !ignoringMarkings else { return }
        guard page != nil, prepareForPageChange() else { return }
        session.resetStages(); committedLayout = layout; mode = .cropping; controlsVisible = true
        configureCanvas()
    }
    func saveCrop() {
        if persistLayout() {
            committedLayout = layout; mode = .reading; configureCanvas(); revision += 1
            renderedPages.removeAllObjects(); activePreviews.removeAll(); prefetchPages()
        }
    }
    @discardableResult
    private func persistLayout() -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var saved = false
        defer { recordDiagnostic(.saveCrop, state: saved ? .succeeded : .failed, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        saveActivity.begin(.crop)
        if store.saveLayout(layout, page: pageIndex, scoreID: scoreID) {
            saveActivity.finish(.crop)
            saved = true
            return true
        }
        saveActivity.fail(.crop)
        return false
    }
    func cancelCrop() {
        saveActivity.cancel(.crop)
        layout = committedLayout; mode = .reading; configureCanvas(); revision += 1
    }
    func resetCrop() { let divider = layout.divider; layout = PageLayout(); layout.divider = divider }
    func changeDivider(_ fraction: Double, persist: Bool) {
        layout.divider = min(0.75, max(0.25, fraction))
        if persist { persistLayout() }
    }

    func turn(forward: Bool, annotationArrow: Bool = false) {
        guard page != nil, !store.isImporting, mode != .cropping, !recoveryAvailable,
              canvas.drawingGestureRecognizer.state != .began,
              canvas.drawingGestureRecognizer.state != .changed else { return }
        let resumeAnnotation = mode == .annotating
        var next = session
        let half = allowsHalfTurn && !resumeAnnotation && !annotationArrow
        let landscape = landscapeSteps && !resumeAnnotation
        if forward { next.next(halfPage: half, landscape: landscape, continueQueue: settings.continueSetlist) }
        else { next.previous(halfPage: half, landscape: landscape, continueQueue: settings.continueSetlist) }
        if next.position == session.position, next.showingTransition, !session.showingTransition {
            // The first half turn displays the next page before changing position.
            // Validate that page too, so damaged ink cannot leave an empty preview.
            var destination = session
            destination.next(halfPage: false, landscape: false, continueQueue: settings.continueSetlist)
            do { _ = try preparePage(destination) }
            catch {
                failedNavigation(error, target: destination, forward: forward, resumeAnnotation: resumeAnnotation)
                return
            }
        }
        _ = navigate(to: next, forward: forward, resumeAnnotation: resumeAnnotation)
    }
    @discardableResult
    func seek(_ page: Int) -> Bool {
        guard self.page != nil, !store.isImporting, mode != .cropping, !recoveryAvailable,
              (session.item.startPage...session.item.endPage).contains(page),
              canvas.drawingGestureRecognizer.state != .began,
              canvas.drawingGestureRecognizer.state != .changed else { return false }
        var target = session
        target.seek(to: page)
        return navigate(to: target, forward: page >= pageIndex, resumeAnnotation: false)
    }
    func orientationChanged(landscape: Bool) {
        guard landscape != isLandscape else { return }
        rememberViewport()
        isLandscape = landscape; session.resetStages(); revision += 1; configureCanvas()
        prefetchPages()
    }
    func refreshSettings() { session.resetStages(); configureCanvas(); revision += 1; prefetchPages() }

    func toggleInkVisibility() {
        inkVisible.toggle(); revision += 1; prefetchPages()
    }

    func rememberViewport() {
        guard page != nil, mode != .cropping, !session.showingTransition else { return }
        viewport.normalize(); zoomed = viewport.scale > 1.02
        let prior = readingProgress.viewport(scoreID: scoreID, page: pageIndex) ?? currentScore?.viewports[pageIndex] ?? PageViewport()
        guard viewport != prior else { return }
        readingProgress.recordViewport(viewport, scoreID: scoreID, page: pageIndex)
        renderedPages.removeAllObjects(); activePreviews.removeAll(); prefetchPages()
        revision += 1; scheduleProgressSave()
    }

    func resetViewport() {
        guard mode == .reading else { return }
        session.resetStages(); viewport = PageViewport(); zoomed = false
        rememberViewport(); revision += 1
    }

    private func scheduleProgressSave() {
        saveActivity.begin(.readingProgress)
        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.flushReadingProgress()
        }
    }

    private func flushReadingProgress() {
        progressSaveTask?.cancel(); progressSaveTask = nil
        guard !readingProgress.isEmpty else { return }
        let start = ProcessInfo.processInfo.systemUptime
        var saved = false
        defer { recordDiagnostic(.saveProgress, state: saved ? .succeeded : .failed, durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        let progress = readingProgress
        if store.update({ progress.apply(to: &$0) }) {
            readingProgress.removeAll(); saveActivity.finish(.readingProgress)
            saved = true
        } else { saveActivity.fail(.readingProgress) }
    }

    private func imageKey(id: UUID, page: Int) -> NSString { "\(id)-\(page)-\(inkVisible)-\(ignoredMarkingPages.contains("\(id)-\(page)"))" as NSString }

    /// Render on an independent PDFDocument so Pencil drawing and the PDF viewport remain responsive.
    private func prefetchPages() {
        updatePaperPreviewRequests()
        prefetchTask?.cancel()
        // Full-page/landscape reading uses tiled vector paper, not transition rasters.
        guard settings.halfPageTurns && !isLandscape else {
            prefetchTask = nil
            renderedPages.removeAllObjects(); activePreviews.removeAll()
            return
        }
        let activePositions = [session.position, session.nextPosition(continueQueue: settings.continueSetlist)].compactMap { $0 }
        let activeKeys = Set(activePositions.map { imageKey(id: session.queue[$0.itemIndex].scoreID, page: $0.page) })
        activePreviews = activePreviews.filter { activeKeys.contains($0.key) }
        for key in activeKeys where activePreviews[key] == nil {
            activePreviews[key] = renderedPages.object(forKey: key)
        }
        let positions = [session.position, session.nextPosition(continueQueue: settings.continueSetlist),
                         session.previousPosition(continueQueue: settings.continueSetlist)].compactMap { $0 }
        let requests = positions.compactMap { position -> (NSString, URL, Int, PageLayout, URL?)? in
            let id = session.queue[position.itemIndex].scoreID
            let key = imageKey(id: id, page: position.page)
            guard activePreviews[key] == nil, renderedPages.object(forKey: key) == nil, let url = store.fileURL(id), let disk = store.disk else { return nil }
            let inkURL = inkVisible && !ignoredMarkingPages.contains("\(id)-\(position.page)") ? disk.inkURL(id, page: position.page) : nil
            let viewport = readingProgress.viewport(scoreID: id, page: position.page) ?? store.score(id)?.viewports[position.page] ?? PageViewport()
            let layout = viewport.applying(to: store.score(id)?.layouts[position.page] ?? PageLayout())
            return (key, url, position.page, layout, inkURL)
        }
        let worker = renderWorker
        prefetchTask = Task { [weak self] in
            for (key, url, index, layout, inkURL) in requests {
                guard !Task.isCancelled else { return }
                let rendered = try? await worker.run { () -> PagePreview? in
                    guard let document = PDFDocument(url: url), let page = document.page(at: index) else { return nil }
                    do {
                        let data = try inkURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try LibraryDisk.readBounded($0, maximumBytes: LibraryDisk.maximumDrawingBytes) : nil }
                        let drawing = try data.map { try PKDrawing(data: $0) } ?? PKDrawing()
                        return withExtendedLifetime(document) {
                            PagePreview(image: PageRendering.image(page: page, drawing: drawing, layout: layout),
                                        canonicalSize: PageRendering.size(of: page))
                        }
                    } catch { return nil }
                }
                guard !Task.isCancelled else { return }
                if let preview = rendered {
                    let cost = preview.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                    self?.renderedPages.setObject(preview, forKey: key, cost: cost)
                    if activeKeys.contains(key) { self?.activePreviews[key] = preview }
                    // Repaint when a missing preview becomes available; input never waits for it.
                    self?.revision += 1
                }
            }
        }
    }

    @objc private func releasePreviewMemory() {
        paperPreviewPaused = true
        paperPreviews.removeAll()
        prefetchTask?.cancel(); prefetchTask = nil
        renderedPages.removeAllObjects(); activePreviews.removeAll()
        // Visible paper/ink and any displayed half-page images keep their ownership.
        // New navigation can prepare previews again without refilling during pressure.
    }

    func transitionImage(next: Bool) -> UIImage? {
        transitionPreview(next: next)?.image
    }

    private var currentPaperPreviewKey: PaperPreviewKey { .init(scoreID: scoreID, page: pageIndex) }
    private var allowsPaperPreview: Bool {
        paperPreviewActive && !paperPreviewPaused && mode == .reading &&
        (!settings.halfPageTurns || isLandscape) && !session.showingTransition && page != nil
    }

    var paperPreview: PaperPreview? {
        allowsPaperPreview ? paperPreviews.preview(for: currentPaperPreviewKey) : nil
    }

    func suspendPaperPreviews() {
        paperPreviewActive = false
        paperPreviews.removeAll()
    }

    func resumePaperPreviews() {
        paperPreviewActive = true; paperPreviewPaused = false
        updatePaperPreviewRequests()
    }

    private func updatePaperPreviewRequests() {
        guard allowsPaperPreview else { paperPreviews.removeAll(); return }
        let next = session.nextPosition(continueQueue: settings.continueSetlist)
        let previous = session.previousPosition(continueQueue: settings.continueSetlist)
        let ordered = (paperPreviewForward ? [next, previous] : [previous, next]).compactMap { $0 }
        let requests = ordered.compactMap { position -> PaperPreviewRequest? in
            let id = session.queue[position.itemIndex].scoreID
            guard let url = store.fileURL(id) else { return nil }
            return .init(key: .init(scoreID: id, page: position.page), url: url)
        }
        var wanted = Set(requests.map(\.key)); wanted.insert(currentPaperPreviewKey)
        paperPreviews.request(requests, retaining: wanted, delayNanoseconds: hasNavigated ? 20_000_000 : 100_000_000)
    }

    func transitionSize(next: Bool) -> CGSize? {
        transitionPreview(next: next)?.canonicalSize
    }

    private func transitionPreview(next: Bool) -> PagePreview? {
        let position: ReadingPosition
        if next {
            guard let nextPosition = session.nextPosition(continueQueue: settings.continueSetlist) else { return nil }
            position = nextPosition
        } else { position = session.position }
        let key = imageKey(id: session.queue[position.itemIndex].scoreID, page: position.page)
        return activePreviews[key] ?? renderedPages.object(forKey: key)
    }

    var bookmarkLabel: String? {
        currentScore?.bookmarks.filter { $0.startPage <= pageIndex }.max { $0.startPage < $1.startPage }?.title
    }
}

extension UIColor {
    convenience init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x252525
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
