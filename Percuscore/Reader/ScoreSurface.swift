import SwiftUI
import PencilKit

struct ScoreSurface: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    var displayOptions: () -> Void
    var inputEnabled = true
    func makeUIView(context: Context) -> ScoreSurfaceView {
        let view = ScoreSurfaceView(model: model, displayOptions: displayOptions)
        view.readerInputEnabled = inputEnabled
        return view
    }
    func updateUIView(_ view: ScoreSurfaceView, context: Context) {
        view.requestRefresh(inputEnabled: inputEnabled)
    }
    static func dismantleUIView(_ view: ScoreSurfaceView, coordinator: ()) { view.invalidate() }
}

@MainActor
final class ScoreSurfaceView: UIView, UIGestureRecognizerDelegate {
    private let model: ReaderModel
    private let showDisplayOptions: () -> Void
    private let scroll = UIScrollView()
    private let stage = UIView()
    private let viewport = UIView()
    private let pageContainer = UIView()
    private var paper: PDFPaperView?
    private let paperPreview = UIImageView()
    private let halfTop = UIView()
    private let halfBottom = UIView()
    private let currentImage = UIImageView()
    private let nextImage = UIImageView()
    private let nextHalfLoading = UIActivityIndicatorView(style: .medium)
    private let divider = AdjustableDividerView()
    private let accessiblePage = UIView()
    private let dividerLine = UIView()
    private let dividerTrailingLine = UIView()
    private let dividerHandle = UIVisualEffectView()
    private let dividerGrip = UIView()
    private let dividerLabelBackground = UIVisualEffectView()
    private let dividerLabel = UILabel()
    private var renderedRevision = -1
    private var cropPan: UIPanGestureRecognizer!
    private var cropPinch: UIPinchGestureRecognizer!
    private var dragStart = PageLayout()
    private var pinchingStart = PageLayout()
    private var lastBounds = CGRect.zero
    private let viewPan = UIPanGestureRecognizer()
    private let viewPinch = UIPinchGestureRecognizer()
    private var manualDragStart = PageViewport()
    private var manualPinchStart = PageViewport()
    private var pinchAnchor = CGPoint.zero
    private var dragPage: String?
    private var pinchPage: String?
    private var pageFit: CGFloat = 1
    private let edgeTap = UITapGestureRecognizer()
    private let centerTap = UITapGestureRecognizer()
    private let centerDoubleTap = UITapGestureRecognizer()
    private let toolPicker = PKToolPicker()
    private var attachedCanvas: PKCanvasView?
    private var toolPickerVisible = false
    private var inputUpdatePending = false
    private var inputSuspended = false
    private var isDismantled = false
    // Presented panels own their keyboard focus until they are dismissed.
    var readerInputEnabled = true
    private var showingHalfPreview = false
    private var usingVectorHalf = false

    /// iPadOS can update the representable on Core Animation's image-provider
    /// queue during tiled rendering. Never read the model or mutate UIKit there.
    nonisolated func requestRefresh(inputEnabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDismantled else { return }
            self.readerInputEnabled = inputEnabled
            self.refresh()
        }
    }

    nonisolated func invalidate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDismantled = true
            self.hideToolPicker()
        }
    }

    init(model: ReaderModel, displayOptions: @escaping () -> Void) {
        self.model = model; self.showDisplayOptions = displayOptions
        super.init(frame: .zero)
        toolPicker.showsDrawingPolicyControls = false
        backgroundColor = .white
        clipsToBounds = true
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 1
        scroll.isScrollEnabled = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        scroll.bouncesZoom = true; scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.panGestureRecognizer.isEnabled = false
        scroll.pinchGestureRecognizer?.isEnabled = false
        addSubview(scroll); scroll.addSubview(stage); stage.clipsToBounds = true
        stage.addSubview(viewport); viewport.clipsToBounds = true; viewport.backgroundColor = .white
        viewport.addSubview(pageContainer); pageContainer.addSubview(paperPreview)
        paperPreview.isUserInteractionEnabled = false
        paperPreview.accessibilityElementsHidden = true
        paperPreview.contentMode = .scaleToFill
        synchronizeCanvas()
        stage.addSubview(halfTop); stage.addSubview(halfBottom)
        halfTop.clipsToBounds = true; halfBottom.clipsToBounds = true
        halfTop.backgroundColor = .white; halfBottom.backgroundColor = .white
        halfTop.addSubview(currentImage); halfBottom.addSubview(nextImage)
        halfBottom.addSubview(nextHalfLoading)
        nextHalfLoading.accessibilityLabel = "Loading next half-page"
        stage.addSubview(accessiblePage)
        accessiblePage.isAccessibilityElement = true
        accessiblePage.isUserInteractionEnabled = false
        accessiblePage.accessibilityLabel = "Score page"
        viewport.accessibilityElementsHidden = true
        halfTop.accessibilityElementsHidden = true
        halfBottom.accessibilityElementsHidden = true
        stage.addSubview(divider)
        divider.addSubview(dividerLine); divider.addSubview(dividerTrailingLine)
        divider.addSubview(dividerHandle); divider.addSubview(dividerLabelBackground)
        dividerHandle.contentView.addSubview(dividerGrip)
        dividerLabelBackground.contentView.addSubview(dividerLabel)
        dividerLine.backgroundColor = UIColor(Theme.accent); dividerGrip.backgroundColor = UIColor(Theme.accent)
        dividerTrailingLine.backgroundColor = UIColor(Theme.accent)
        dividerHandle.layer.cornerRadius = 16; dividerHandle.clipsToBounds = true
        dividerGrip.layer.cornerRadius = 2
        dividerLabelBackground.layer.cornerRadius = 14; dividerLabelBackground.clipsToBounds = true
        dividerLabel.textColor = UIColor(Theme.accent)
        dividerLabel.font = .preferredFont(forTextStyle: .caption1)
        dividerLabel.adjustsFontForContentSizeCategory = true
        dividerLabel.textAlignment = .center
        dividerLabel.numberOfLines = 2
        refreshDividerMaterial()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDividerMaterial),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releasePaperPreview),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let dividerPan = UIPanGestureRecognizer(target: self, action: #selector(moveDivider(_:)))
        dividerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        divider.addGestureRecognizer(dividerPan)
        divider.isAccessibilityElement = true
        divider.accessibilityLabel = "Half-page divider"
        divider.adjust = { [weak self] direction in
            guard let self, self.model.session.showingTransition,
                  self.model.mode == .reading, !self.model.performance.isActive,
                  !self.model.recoveryAvailable, !self.model.store.isImporting else { return }
            let next = Double(self.model.layout.dividerPercentage) + direction * 5
            self.model.changeDivider(next / 100, persist: true)
            self.refresh()
        }

        edgeTap.addTarget(self, action: #selector(tapPage(_:)))
        centerTap.addTarget(self, action: #selector(tapPage(_:)))
        centerDoubleTap.addTarget(self, action: #selector(doubleTap(_:)))
        centerDoubleTap.numberOfTapsRequired = 2
        // Only center taps wait for a double tap. Every edge tap turns immediately.
        centerTap.require(toFail: centerDoubleTap)
        let left = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:))); left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:))); right.direction = .right
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.minimumPressDuration = 0.55
        for gesture in [edgeTap, centerTap, centerDoubleTap, left, right, long] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.delegate = self; gesture.cancelsTouchesInView = false; addGestureRecognizer(gesture)
        }
        cropPan = UIPanGestureRecognizer(target: self, action: #selector(panCrop(_:)))
        cropPan.maximumNumberOfTouches = 1
        cropPinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchCrop(_:)))
        cropPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cropPinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(cropPan); addGestureRecognizer(cropPinch)
        viewPan.minimumNumberOfTouches = 2; viewPan.maximumNumberOfTouches = 2
        viewPan.addTarget(self, action: #selector(movePage(_:)))
        viewPinch.addTarget(self, action: #selector(zoomPage(_:)))
        for gesture in [viewPan, viewPinch] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.delegate = self; addGestureRecognizer(gesture)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func releasePaperPreview() {
        paperPreview.image = nil; paperPreview.isHidden = true
    }
    @objc private func refreshDividerMaterial() {
        for badge in [dividerHandle, dividerLabelBackground] {
            if UIAccessibility.isReduceTransparencyEnabled {
                badge.effect = nil
                badge.backgroundColor = .secondarySystemGroupedBackground
            } else {
                badge.effect = UIBlurEffect(style: .systemMaterial)
                badge.backgroundColor = .clear
            }
        }
    }
    override var canBecomeFirstResponder: Bool { readerInputEnabled }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextPage)),
         UIKeyCommand(input: " ", modifierFlags: [], action: #selector(nextPage)),
         UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousPage))]
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        inputSuspended = window == nil
        scheduleInputUpdate()
    }

    func hideToolPicker() {
        inputSuspended = true
        scheduleInputUpdate()
    }

    private func hideToolPickerImmediately() {
        if let attachedCanvas {
            toolPicker.setVisible(false, forFirstResponder: attachedCanvas)
            attachedCanvas.resignFirstResponder()
        }
        toolPickerVisible = false
    }

    private func synchronizeCanvas() {
        guard attachedCanvas !== model.canvas else { return }
        hideToolPickerImmediately()
        if let previous = attachedCanvas {
            toolPicker.removeObserver(previous)
            previous.removeFromSuperview()
        }
        attachedCanvas = model.canvas
        model.canvas.tool = toolPicker.selectedTool
        toolPicker.addObserver(model.canvas)
        pageContainer.addSubview(model.canvas)
    }

    private func scheduleInputUpdate() {
        guard !inputUpdatePending else { return }
        inputUpdatePending = true
        let queuedAt = ProcessInfo.processInfo.systemUptime
        // Changing first responder inside updateUIView makes the hosting view
        // re-enter its responder graph while SwiftUI is updating that graph.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                let detached = self.window == nil || self.inputSuspended || self.isDismantled || !self.readerInputEnabled
                let focused = self.model.mode == .annotating ? self.model.canvas.isFirstResponder : self.isFirstResponder
                self.model.recordDiagnostic(.focusUpdate, state: detached ? .detached : (self.model.mode == .cropping || focused ? .succeeded : .failed),
                    durationMS: (ProcessInfo.processInfo.systemUptime - queuedAt) * 1000)
            }
            self.inputUpdatePending = false
            guard self.window != nil, !self.inputSuspended, !self.isDismantled, self.readerInputEnabled else {
                self.hideToolPickerImmediately()
                if self.isFirstResponder { self.resignFirstResponder() }
                return
            }
            // Read the current mode/canvas here, not when the update was queued:
            // Done, page turns and dismissal may all happen before this runs.
            self.synchronizeCanvas()
            if self.model.mode == .cropping, self.isFirstResponder { self.resignFirstResponder() }
            self.refreshToolPicker()
            if self.model.mode == .reading, !self.isFirstResponder { self.becomeFirstResponder() }
            self.setNeedsLayout()
        }
    }

    private func refreshToolPicker() {
        let visible = window != nil && model.mode == .annotating && !model.performance.isActive && !model.recoveryAvailable
        // Save-and-turn briefly exits annotation without hiding the picker.
        // Restore the ruler state on the new page as well as on initial presentation.
        if visible { model.canvas.isRulerActive = toolPicker.isRulerActive }
        guard visible != toolPickerVisible else { return }
        toolPickerVisible = visible
        if visible {
            model.canvas.tool = toolPicker.selectedTool
            toolPicker.setVisible(true, forFirstResponder: model.canvas)
            model.canvas.becomeFirstResponder()
        } else {
            hideToolPickerImmediately()
            if window != nil && model.mode != .cropping { becomeFirstResponder() }
        }
    }

    func refresh() {
        guard !isDismantled else { return }
        let pageChanged = attachedCanvas !== model.canvas
        // An unattached view cannot affect the hosting responder chain. Live
        // canvas replacement (which can resign the old canvas) is deferred too.
        if window == nil { synchronizeCanvas() }
        if window != nil { inputSuspended = false }
        scheduleInputUpdate()
        let cropping = model.mode == .cropping
        centerDoubleTap.isEnabled = !model.performance.isActive && model.mode == .reading
        cropPan.isEnabled = cropping; cropPinch.isEnabled = cropping
        let manualView = !cropping && !model.session.showingTransition && model.page != nil && !model.recoveryAvailable && !model.store.isImporting
        viewPan.isEnabled = manualView; viewPinch.isEnabled = manualView
        if paper?.page !== model.page {
            paper?.removeFromSuperview()
            paper = model.page.map { PDFPaperView(page: $0) }
            if let paper { pageContainer.insertSubview(paper, aboveSubview: paperPreview) }
        }
        paperPreview.image = model.paperPreview?.image
        paperPreview.isHidden = paperPreview.image == nil
        model.configureCanvas()
        if renderedRevision != model.revision || pageChanged {
            renderedRevision = model.revision
            if model.session.showingTransition {
                currentImage.image = model.transitionImage(next: false)
                nextImage.image = model.transitionImage(next: true)
            } else {
                currentImage.image = nil
                nextImage.image = nil
            }
        }
        if let next = model.session.nextPosition(continueQueue: model.settings.continueSetlist) {
            dividerLabel.text = "\(model.layout.dividerPercentage)% · P. \(model.pageIndex + 1) / P. \(next.page + 1)"
        }
        showingHalfPreview = model.session.showingTransition
        // The first half-turn must visibly move immediately, even before previews are cached.
        // Use the live PDF and ink for the current bottom half until the bitmap is ready.
        usingVectorHalf = showingHalfPreview && currentImage.image == nil
        if usingVectorHalf {
            if viewport.superview !== halfTop { halfTop.addSubview(viewport) }
        } else if viewport.superview !== stage { stage.insertSubview(viewport, at: 0) }
        viewport.isHidden = showingHalfPreview && !usingVectorHalf
        currentImage.isHidden = usingVectorHalf
        halfTop.isHidden = !showingHalfPreview; halfBottom.isHidden = !showingHalfPreview
        if showingHalfPreview && nextImage.image == nil { nextHalfLoading.startAnimating() }
        else { nextHalfLoading.stopAnimating() }
        divider.isUserInteractionEnabled = !model.performance.isActive
        divider.isHidden = !showingHalfPreview
        refreshAccessibility()
        setNeedsLayout()
    }

    private func refreshAccessibility() {
        divider.accessibilityValue = "\(model.layout.dividerPercentage) percent from top"
        divider.accessibilityTraits = model.performance.isActive ? [.notEnabled] : [.adjustable]
        divider.accessibilityHint = model.performance.isActive
            ? "Position is locked during performance."
            : "Swipe up or down to move five percent. Drag to adjust with touch."
        accessiblePage.accessibilityValue = "\(model.session.item.title), page \(model.pageIndex + 1) of \(model.currentScore?.pageCount ?? 0)"
            + (showingHalfPreview ? ", half-page transition" : "")
        accessiblePage.accessibilityHint = model.mode == .cropping
            ? "Use the crop sliders to adjust scale, position and rotation."
            : "Use Actions to turn pages or reveal controls. Music notation is displayed visually."
        var actions: [UIAccessibilityCustomAction] = []
        if model.mode == .reading && !model.recoveryAvailable && !model.store.isImporting {
            for (name, forward) in [("Previous page", false), ("Next page", true)] {
                actions.append(UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    guard let self else { return false }
                    let before = self.model.session.position
                    self.model.turn(forward: forward); self.refresh()
                    guard before != self.model.session.position else { return false }
                    UIAccessibility.post(notification: .pageScrolled, argument: self.accessiblePage.accessibilityValue)
                    return true
                })
            }
            actions.append(UIAccessibilityCustomAction(name: model.performance.isActive ? "Exit performance" : (model.controlsVisible ? "Hide reader controls" : "Show reader controls")) { [weak self] _ in
                guard let self else { return false }
                if self.model.performance.isActive { self.model.exitPerformance() }
                else { self.model.controlsVisible.toggle() }
                self.refresh()
                return true
            })
        }
        accessiblePage.accessibilityCustomActions = actions
        stage.accessibilityElements = showingHalfPreview ? [accessiblePage, divider] : [accessiblePage]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let page = model.page else { return }
        if lastBounds != bounds {
            lastBounds = bounds
        }
        scroll.frame = bounds
        stage.frame = bounds; scroll.contentSize = bounds.size
        let canonical = PageRendering.size(of: page)
        let available = model.mode == .cropping ? bounds.insetBy(dx: 16, dy: 12) : bounds
        let landscape = model.landscapeSteps && model.mode == .reading
        let fit = landscape ? available.width / canonical.width : min(available.width / canonical.width, available.height / canonical.height)
        pageFit = fit
        let size = CGSize(width: canonical.width * fit, height: canonical.height * fit)
        let y = landscape ? (model.session.landscapeBottom ? available.maxY - size.height : available.minY) : (bounds.height - size.height) / 2
        let pageFrame = CGRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        accessiblePage.frame = pageFrame
        viewport.frame = pageFrame
        // Full-page zoom may extend through the fitted page's letterboxing.
        // The stage clips at the window edge; crop and half-turns keep their masks.
        viewport.clipsToBounds = model.mode == .cropping || showingHalfPreview
        pageContainer.transform = .identity
        pageContainer.bounds = CGRect(origin: .zero, size: canonical)
        paper?.frame = pageContainer.bounds
        paperPreview.frame = pageContainer.bounds
        model.canvas.frame = pageContainer.bounds; model.canvas.contentSize = canonical
        let displayLayout = model.mode == .cropping ? model.layout : model.viewport.applying(to: model.layout)
        pageContainer.center = CGPoint(x: (canonical.width / 2 + canonical.width * displayLayout.offsetX) * fit,
                                       y: (canonical.height / 2 + canonical.height * displayLayout.offsetY) * fit)
        pageContainer.transform = CGAffineTransform(rotationAngle: displayLayout.rotation * .pi / 180)
            .scaledBy(x: fit * displayLayout.scale, y: fit * displayLayout.scale)
        if showingHalfPreview {
            let frame = pageFrame
            let height = frame.height * model.layout.boundedDivider
            halfTop.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
            halfBottom.frame = CGRect(x: frame.minX, y: frame.minY + height, width: frame.width, height: frame.height - height)
            if usingVectorHalf {
                viewport.frame = CGRect(x: 0, y: height - frame.height, width: frame.width, height: frame.height)
            }
            nextHalfLoading.center = CGPoint(x: halfBottom.bounds.midX, y: halfBottom.bounds.midY)
            currentImage.contentMode = .scaleToFill
            currentImage.frame = CGRect(x: 0, y: height - frame.height, width: frame.width, height: frame.height)
            // Preserve next page aspect ratio even when a setlist changes paper size.
            let nextSize = model.transitionSize(next: true) ?? canonical
            let scaledHeight = (nextSize.height / max(1, nextSize.width)) * frame.width
            let nextHeight = scaledHeight.isFinite && scaledHeight > 0 ? scaledHeight : frame.height
            nextImage.contentMode = .scaleToFill
            nextImage.frame = CGRect(x: 0, y: 0, width: frame.width, height: nextHeight)
            let largeText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            let labelSize = dividerLabel.sizeThatFits(CGSize(width: min(200, frame.width * 0.6), height: .greatestFiniteMagnitude))
            let badgeHeight = max(44, labelSize.height + 12)
            divider.frame = CGRect(x: frame.minX, y: frame.minY + height - badgeHeight / 2, width: frame.width, height: badgeHeight)
            let labelWidth = largeText ? min(200, frame.width * 0.6) : 120
            let handleX = largeText ? frame.width - 80 : frame.width / 2 - 36
            dividerLine.frame = CGRect(x: labelWidth + 16, y: badgeHeight / 2 - 1, width: max(0, handleX - labelWidth - 24), height: 3)
            dividerTrailingLine.frame = CGRect(x: handleX + 80, y: badgeHeight / 2 - 1, width: max(0, frame.width - handleX - 80), height: 3)
            dividerHandle.frame = CGRect(x: handleX, y: (badgeHeight - 32) / 2, width: 72, height: 32)
            dividerGrip.frame = CGRect(x: 20, y: 14, width: 32, height: 4)
            dividerLabelBackground.frame = CGRect(x: 8, y: 0, width: labelWidth, height: badgeHeight)
            dividerLabel.frame = dividerLabelBackground.bounds.insetBy(dx: 6, dy: 4)
            if let next = model.session.nextPosition(continueQueue: model.settings.continueSetlist) {
                dividerLabel.text = "\(model.layout.dividerPercentage)% · P. \(model.pageIndex + 1) / P. \(next.page + 1)"
            }
        }
    }
    private var pageKey: String { "\(model.scoreID)-\(model.pageIndex)" }

    @objc func zoomPage(_ gesture: UIPinchGestureRecognizer) {
        guard model.mode != .cropping, !model.session.showingTransition, !model.recoveryAvailable else { return }
        if gesture.state == .began {
            pinchPage = pageKey; manualPinchStart = model.viewport
            pinchAnchor = pageContainer.convert(gesture.location(in: viewport), from: viewport)
        }
        guard pinchPage == pageKey else { return }
        if gesture.state == .began || gesture.state == .changed {
            var value = model.viewport
            value.scale = manualPinchStart.scale * gesture.scale; value.normalize()
            model.viewport = value
            setNeedsLayout(); layoutIfNeeded()
            let shown = pageContainer.convert(pinchAnchor, to: viewport)
            let focal = gesture.location(in: viewport)
            value.offsetX += (focal.x - shown.x) / max(1, model.canvas.bounds.width * pageFit)
            value.offsetY += (focal.y - shown.y) / max(1, model.canvas.bounds.height * pageFit)
            value.normalize(); model.viewport = value; model.zoomed = value.scale > 1.02
            setNeedsLayout()
        }
        if gesture.state == .ended || gesture.state == .cancelled {
            model.rememberViewport(); pinchPage = nil
            manualDragStart = model.viewport; viewPan.setTranslation(.zero, in: viewport)
        }
    }

    @objc func movePage(_ gesture: UIPanGestureRecognizer) {
        guard model.mode != .cropping, !model.session.showingTransition, !model.recoveryAvailable else { return }
        if gesture.state == .began { dragPage = pageKey; manualDragStart = model.viewport }
        guard dragPage == pageKey else { return }
        if viewPinch.state == .began || viewPinch.state == .changed {
            manualDragStart = model.viewport; gesture.setTranslation(.zero, in: viewport)
            return
        }
        if gesture.state == .began || gesture.state == .changed {
            let delta = gesture.translation(in: viewport)
            var value = manualDragStart
            value.offsetX += delta.x / max(1, model.canvas.bounds.width * pageFit)
            value.offsetY += delta.y / max(1, model.canvas.bounds.height * pageFit)
            value.normalize(); model.viewport = value
            setNeedsLayout()
        }
        if gesture.state == .ended || gesture.state == .cancelled { model.rememberViewport(); dragPage = nil }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard model.mode != .cropping, !model.recoveryAvailable else { return false }
        if gestureRecognizer === viewPan || gestureRecognizer === viewPinch {
            let state = model.canvas.drawingGestureRecognizer.state
            return !model.session.showingTransition && state != .began && state != .changed
        }
        if model.performance.isActive {
            if gestureRecognizer is UILongPressGestureRecognizer { return false }
            if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 { return false }
        }
        if model.mode == .annotating && !model.settings.preventFingerDrawing { return false }
        if model.mode == .annotating && model.canvas.tool is PKLassoTool { return false }
        let state = model.canvas.drawingGestureRecognizer.state
        return state != .began && state != .changed
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if !model.performance.isActive, !divider.isHidden, let view = touch.view, view.isDescendant(of: divider) { return false }
        let fraction = touch.location(in: self).x / max(1, bounds.width)
        let atEdge = fraction < 0.25 || fraction > 0.75
        if gestureRecognizer === edgeTap { return atEdge }
        if gestureRecognizer === centerTap || gestureRecognizer === centerDoubleTap { return !atEdge }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === viewPan && other === viewPinch) || (gestureRecognizer === viewPinch && other === viewPan)
    }
    @objc private func tapPage(_ gesture: UITapGestureRecognizer) {
        let fraction = gesture.location(in: self).x / max(1, bounds.width)
        if fraction < 0.25 { model.turn(forward: false) }
        else if fraction > 0.75 { model.turn(forward: true) }
        else if model.performance.isActive { model.performance.tapCenter() }
        else if model.mode == .reading { model.controlsVisible.toggle() }
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        guard !model.performance.isActive else { return }
        let fraction = gesture.location(in: self).x / max(1, bounds.width)
        if (0.25...0.75).contains(fraction), model.mode == .reading { showDisplayOptions() }
    }
    @objc private func swipe(_ gesture: UISwipeGestureRecognizer) { model.turn(forward: gesture.direction == .left) }
    @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { model.beginAnnotation() }
    }
    @objc private func nextPage() { model.turn(forward: true) }
    @objc private func previousPage() { model.turn(forward: false) }
    @objc private func panCrop(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dragStart = model.layout }
        let translation = gesture.translation(in: self)
        model.layout.offsetX = dragStart.offsetX + translation.x / max(1, viewport.bounds.width)
        model.layout.offsetY = dragStart.offsetY + translation.y / max(1, viewport.bounds.height)
        model.layout.normalize(); setNeedsLayout()
    }
    @objc private func pinchCrop(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchingStart = model.layout }
        model.layout.scale = min(3, max(1, pinchingStart.scale * gesture.scale)); setNeedsLayout()
    }
    @objc private func moveDivider(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: stage)
        let fraction = (point.y - viewport.frame.minY) / max(1, viewport.frame.height)
        model.changeDivider(fraction, persist: gesture.state == .ended || gesture.state == .cancelled)
        setNeedsLayout()
    }
}

/// VoiceOver adjustment shares the touch divider's bounds and persistence path.
private final class AdjustableDividerView: UIView {
    var adjust: ((Double) -> Void)?
    override func accessibilityIncrement() { adjust?(1) }
    override func accessibilityDecrement() { adjust?(-1) }
}
