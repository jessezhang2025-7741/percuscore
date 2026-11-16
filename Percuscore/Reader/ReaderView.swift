import SwiftUI
import UIKit

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: ReaderModel
    @ObservedObject private var store: LibraryStore
    @State private var bookmarks = false
    @State private var pageNavigator = false
    @State private var exportingScore: Score?
    @State private var displayOptions = false
    @State private var cropAdjustments = false
    @State private var cropHelp = false
    @State private var seekValue: Double
    @State private var seeking = false
    @State private var dropTarget = false
    @State private var controlsInteraction = UUID()

    private struct ControlsHideRequest: Equatable {
        let enabled: Bool
        let interaction: UUID
    }

    init(store: LibraryStore, session: ReadingSession) {
        self.store = store
        _model = StateObject(wrappedValue: ReaderModel(store: store, session: session))
        _seekValue = State(initialValue: Double(session.position.page))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.ignoresSafeArea()
                ScoreSurface(model: model, displayOptions: { displayOptions = true }, inputEnabled: readerInputEnabled)
                    // Reading and annotation share the full canvas so Pencil's first stroke
                    // does not move when its toolbar appears. Only Crop reserves editing space.
                    .padding(.top, model.mode == .cropping ? 66 : 0)
                    .padding(.bottom, model.mode == .cropping ? (dynamicTypeSize.isAccessibilitySize ? 390 : 180) : 0)
                    .ignoresSafeArea(.container)
                if model.page == nil {
                    ContentUnavailableView("Unable to open this page", systemImage: "doc.badge.ellipsis", description: Text("Your library files have been preserved."))
                        .foregroundStyle(.black)
                }
                if model.controlsVisible && !model.performance.isActive {
                    GlassControlGroup(spacing: 8) {
                        VStack(spacing: 8) {
                            if model.mode == .annotating { annotationToolbar }
                            else { header(compact: geometry.size.width < 640) }
                            saveStatusBadge
                            if model.mode == .cropping { cropInstruction }
                            Spacer(minLength: 0)
                            if model.mode == .cropping { cropControls }
                            else { pageControls }
                        }
                    }
                }
                if model.performance.isActive && model.performance.exitVisible {
                    VStack {
                        Button { model.exitPerformance() } label: {
                            Label("Exit performance", systemImage: "xmark.circle.fill")
                                .font(.headline).padding(8)
                        }.buttonStyle(GlassActionStyle()).padding(.top, 12)
                        Spacer()
                    }
                }
                if dropTarget {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(14).allowsHitTesting(false)
                }
                if store.isImporting {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    HStack { ProgressView(); Text(store.importProgress) }.padding(20).liquidGlass(in: Capsule())
                }
            }
            .overlay(alignment: .top) {
                NavigationRecoveryNotice(model: model).padding(16)
            }
            .onAppear {
                model.resumePaperPreviews()
                model.orientationChanged(landscape: geometry.size.width > geometry.size.height)
                updateIdleTimer()
            }
            .onChange(of: geometry.size) { _, size in model.orientationChanged(landscape: size.width > size.height) }
        }
        .statusBarHidden(!model.controlsVisible)
        .persistentSystemOverlays(model.controlsVisible ? .automatic : .hidden)
        .task(id: ControlsHideRequest(enabled: shouldAutoHideControls, interaction: controlsInteraction)) {
            guard shouldAutoHideControls else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return } // A new reveal, modal or lifecycle change cancels the old deadline.
            guard !Task.isCancelled, shouldAutoHideControls else { return }
            withAnimation(.easeOut(duration: 0.2)) { model.controlsVisible = false }
        }
        .onDisappear { model.suspendPaperPreviews(); model.flushDraft(); UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            if let state = ReaderDiagnosticEvent.State(rawValue: String(describing: phase)) {
                model.recordDiagnostic(.lifecycle, state: state)
            }
            if phase != .active { model.suspendPaperPreviews(); model.flushDraft(); UIApplication.shared.isIdleTimerDisabled = false }
            else { model.resumePaperPreviews(); updateIdleTimer() }
            if phase == .background { model.flushDiagnostics() }
        }
        .onChange(of: model.performance.isActive) { _, _ in updateIdleTimer() }
        .onChange(of: model.session.position.page) { _, page in if !seeking { seekValue = Double(page) } }
        .onChange(of: store.index.settings) { _, settings in
            model.refreshSettings(); updateIdleTimer()
        }
        .onDrop(of: ["com.adobe.pdf"], isTargeted: $dropTarget) { providers in
            guard !model.performance.isActive, model.prepareForPageChange() else { return false }
            return store.receiveDrop(providers) { ids in
                guard let id = ids.first, let item = store.index.resolve(.init(scoreID: id)),
                      let session = ReadingSession(queue: [item]) else { return }
                _ = model.openSession(session)
                seekValue = Double(model.pageIndex)
            }
        }
        .sheet(item: $exportingScore) { score in PDFExportView(score: score).environmentObject(store) }
        // Independent panels can use native glass; tiled-paper chrome stays protected.
        .sheet(isPresented: $bookmarks) {
            BookmarkPanel(model: model, store: store).environment(\.stableReaderChrome, false)
        }
        .sheet(isPresented: $pageNavigator) {
            PageNavigatorPanel(model: model, store: store).environment(\.stableReaderChrome, false)
        }
        .sheet(isPresented: $cropAdjustments) { cropAdjustmentsPanel }
        .sheet(isPresented: $displayOptions) {
            SettingsView(allowsBackup: false).environmentObject(store).environment(\.stableReaderChrome, false)
        }
        .alert("Crop page", isPresented: $cropHelp) {
            Button("OK") { cropHelp = false }
        } message: {
            Text("Drag the score to position it, pinch to enlarge, or use Adjust crop for precise VoiceOver controls. Keep every marking in view.")
        }
        .alert("Recover unsaved markings?", isPresented: $model.recoveryAvailable) {
            Button("Recover") { model.recoverDraft() }
            Button("Discard draft", role: .destructive) { model.discardRecovery() }
        } message: { Text("A draft from your previous session was found on this page. Your last confirmed markings are still saved separately.") }
        .alert("Percuscore", isPresented: Binding(get: { !pageNavigator && ((model.navigationFailure == nil && model.errorMessage != nil) || store.errorMessage != nil) }, set: { if !$0 { model.errorMessage = nil; store.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil; store.errorMessage = nil }
        } message: { Text(model.errorMessage ?? store.errorMessage ?? "") }
        // Real iPad crash reports show native glass group updates executing on
        // Core Animation's image-provider queue while the tiled PDF is rendering.
        .environment(\.stableReaderChrome, true)
    }

    private var readerInputEnabled: Bool {
        !bookmarks && !pageNavigator && exportingScore == nil && !displayOptions &&
        !cropAdjustments && !cropHelp && !model.recoveryAvailable &&
        (model.navigationFailure != nil || model.errorMessage == nil) && store.errorMessage == nil
    }

    private var shouldAutoHideControls: Bool {
        model.controlsVisible && model.mode == .reading && !model.performance.isActive &&
        model.page != nil && scenePhase == .active && !store.isImporting && !dropTarget &&
        !bookmarks && !pageNavigator && exportingScore == nil && !displayOptions &&
        !cropAdjustments && !cropHelp && !seeking && !model.recoveryAvailable &&
        model.navigationFailure == nil && model.errorMessage == nil && store.errorMessage == nil &&
        model.saveState != .failed
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = model.performance.keepAwake(
            preference: store.index.settings.keepScreenAwake, appActive: scenePhase == .active)
    }

    @ViewBuilder private var saveStatusBadge: some View {
        if model.saveState != .idle {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if model.saveState == .saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.saveState == .failed ? "exclamationmark.circle.fill" : "checkmark.circle")
                    }
                    Text(saveStatusTitle).font(.caption.weight(.medium))
                }
                .foregroundStyle(model.saveState == .failed ? Color.red : Color.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Save status")
                .accessibilityValue(saveStatusTitle)
                .accessibilityHint(model.saveState == .saved && model.mode == .annotating
                    ? "Markings are saved as a recoverable draft. Tap Done to confirm them."
                    : "Local storage on this iPad.")
                if model.saveState == .failed {
                    Button("Retry") { model.retrySaving() }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        .buttonStyle(.plain).accessibilityLabel("Retry save")
                }
            }.padding(.horizontal, 14).padding(.vertical, model.saveState == .failed ? 0 : 8)
                .liquidGlass(in: Capsule()).padding(.horizontal, 16)
        }
    }
    private var saveStatusTitle: String {
        switch model.saveState {
        case .idle: return ""
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed: return model.saveActivity.hasOnlyCleanupFailure ? "Saved · cleanup pending" : "Save failed"
        }
    }

    private func leaveReader() {
        if model.mode == .cropping { model.saveCrop(); if model.mode == .cropping { return } }
        guard model.prepareForPageChange() else { return }
        model.flushDraft()
        guard model.saveState != .failed else { return }
        dismiss()
    }

    private func libraryButton(iconOnly: Bool = false) -> some View {
        Button(action: leaveReader) {
            if iconOnly {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            } else {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
        }.buttonStyle(GlassActionStyle()).accessibilityLabel("Library")
    }

    private var readerTitle: some View {
        VStack(spacing: 3) {
            Text(model.session.item.title).font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .multilineTextAlignment(.center)
            if model.session.queue.count > 1 {
                Text("SETLIST  ·  \(model.session.position.itemIndex + 1) OF \(model.session.queue.count)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 56).liquidGlass()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current score")
            .accessibilityValue("\(model.session.item.title), page \(model.pageIndex + 1)")
    }

    private var annotateButton: some View {
        Button { model.beginAnnotation() } label: {
            Image(systemName: "pencil.tip").font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Circle())
                .liquidGlass(in: Circle(), interactive: true)
        }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            .accessibilityLabel("Annotate")
            .accessibilityHint("Open the Apple Pencil marking tools.")
            .disabled(model.page == nil || model.recoveryAvailable || model.ignoringMarkings || store.isImporting)
    }

    private var readerActionsMenu: some View {
        Menu {
            Button("Bookmarks", systemImage: "bookmark") { bookmarks = true }
                .disabled(model.page == nil || model.recoveryAvailable)
            Button("Enter performance mode", systemImage: "play.rectangle") { model.enterPerformance() }
                .disabled(model.page == nil || model.recoveryAvailable || store.isImporting)
            Section("Tools") { toolsMenuContents }
            Button("Display options", systemImage: "rectangle.on.rectangle") { displayOptions = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true)
        }.buttonStyle(.plain).foregroundStyle(Theme.accent).accessibilityLabel("Reader actions")
    }

    private func header(compact: Bool) -> some View {
        GlassControlGroup(spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize || (compact && model.mode == .reading) {
                    VStack(spacing: 8) {
                        HStack {
                            libraryButton(iconOnly: compact)
                            Spacer(minLength: 8)
                            if model.mode == .reading { annotateButton; readerActionsMenu }
                        }
                        readerTitle
                    }
                } else {
                    HStack(spacing: 12) {
                        libraryButton()
                        readerTitle
                        if model.mode == .reading {
                            annotateButton
                            if compact { readerActionsMenu }
                            else {
                                HStack(spacing: 4) {
                                    Button { bookmarks = true } label: { Image(systemName: "bookmark").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Bookmarks").disabled(model.page == nil || model.recoveryAvailable)
                                    Button { model.enterPerformance() } label: { Image(systemName: "play.rectangle").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Enter performance mode")
                                        .accessibilityHint("Hides tools and keeps the screen awake. Tap the page center to reveal Exit performance.")
                                        .disabled(model.page == nil || model.recoveryAvailable || store.isImporting)
                                    Menu { toolsMenuContents } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Tools").disabled(model.page == nil || model.recoveryAvailable)
                                    Button { displayOptions = true } label: { Image(systemName: "rectangle.on.rectangle").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Display options")
                                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 8).frame(height: 56).liquidGlass(in: Capsule())
                            }
                        }
                    }
                }
            }
        }.frame(maxWidth: 1100).padding(.horizontal, 16).padding(.top, 8)
            // UIKit menus consume completed taps; reset the deadline at touch-down instead.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0).onEnded { _ in controlsInteraction = UUID() })
    }

    @ViewBuilder private var toolsMenuContents: some View {
        Button("Reset page view", systemImage: "arrow.up.left.and.arrow.down.right") { model.resetViewport() }
            .disabled(model.page == nil || model.recoveryAvailable)
        Button("Crop page", systemImage: "crop") { model.beginCrop() }.disabled(model.ignoringMarkings)
            .disabled(model.page == nil || model.recoveryAvailable)
        Button("Export PDF", systemImage: "square.and.arrow.up") {
            guard model.saveAnnotation() else { return }
            exportingScore = model.currentScore
        }.disabled(model.page == nil || model.recoveryAvailable)
        Button(model.inkVisible ? "Hide annotations" : "Show annotations", systemImage: "eye") { model.toggleInkVisibility() }
            .disabled(model.page == nil || model.recoveryAvailable)
    }

    private var annotationToolbar: some View {
        ViewThatFits(in: .horizontal) {
            annotationControls(showTitle: true, showDoneTitle: true)
            annotationControls(showTitle: false, showDoneTitle: true)
            annotationControls(showTitle: false, showDoneTitle: false)
        }.frame(maxWidth: 860).padding(.horizontal, 16).padding(.top, 8)
    }

    private func annotationControls(showTitle: Bool, showDoneTitle: Bool) -> some View {
        HStack(spacing: 8) {
            if showTitle {
                Label("Markup", systemImage: "pencil.tip").font(.headline)
                    .foregroundStyle(Theme.accent).fixedSize()
                    .padding(.horizontal, 16).frame(height: 56)
                    .liquidGlass(in: Capsule())
            }
            Menu {
                Button("Save and annotate previous page", systemImage: "chevron.left") {
                    model.turn(forward: false, annotationArrow: true)
                }
                Button("Save and annotate next page", systemImage: "chevron.right") {
                    model.turn(forward: true, annotationArrow: true)
                }
                Divider()
                Button("Cancel annotation changes", systemImage: "xmark", role: .destructive) {
                    model.cancelAnnotation()
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .liquidGlass(in: Circle(), interactive: true)
            }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityLabel("Markup actions")

            Button { _ = model.saveAnnotation() } label: {
                Group {
                    if showDoneTitle {
                        Label("Done", systemImage: "checkmark").font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                }.foregroundStyle(.white)
            }.buttonStyle(GlassActionStyle(prominent: true)).accessibilityLabel("Done")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var pageControls: some View {
        VStack(spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 8) {
                    previousPageButton
                    Spacer(minLength: 0)
                    quickPageButton
                    Spacer(minLength: 0)
                    nextPageButton
                }
                pageSlider
                if let seekBookmarkLabel { Text(seekBookmarkLabel).font(.caption).lineLimit(2) }
            } else {
                HStack(spacing: 18) {
                    previousPageButton
                    VStack(spacing: 0) {
                        pageSlider
                        HStack {
                            if let seekBookmarkLabel { Text(seekBookmarkLabel).lineLimit(2) }
                            else { Text("Tap edges to turn · pinch to zoom · two fingers to move").lineLimit(2) }
                            Spacer(minLength: 0)
                            quickPageButton
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    nextPageButton
                }
            }
        }.buttonStyle(.plain).foregroundStyle(.primary).tint(Theme.accent)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .liquidGlass().frame(maxWidth: 860)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0).onEnded { _ in controlsInteraction = UUID() })
    }

    private var previousPageButton: some View {
        Button { model.turn(forward: false) } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Previous page")
    }
    private var nextPageButton: some View {
        Button { model.turn(forward: true) } label: {
            Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Next page")
    }
    private var pageSlider: some View {
        let upper = max(model.session.item.startPage + 1, model.session.item.endPage)
        return Slider(value: $seekValue, in: Double(model.session.item.startPage)...Double(upper), step: 1) { editing in
            seeking = editing
            if !editing { model.seek(Int(seekValue)); seekValue = Double(model.pageIndex) }
        }.disabled(model.session.item.startPage == model.session.item.endPage || model.recoveryAvailable)
            .accessibilityLabel("Page position")
            .accessibilityValue("Page \(Int(seekValue) + 1) of \(model.currentScore?.pageCount ?? 0)")
    }
    private var quickPageButton: some View {
        Button { pageNavigator = true } label: {
            Text("\(Int(seekValue) + 1) / \(model.currentScore?.pageCount ?? 0)")
                .font(.caption.monospacedDigit()).fixedSize()
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.foregroundStyle(Theme.accent)
            .accessibilityLabel("Quick page navigation")
            .accessibilityValue("\(Int(seekValue) + 1) / \(model.currentScore?.pageCount ?? 0)")
            .disabled(model.page == nil || model.recoveryAvailable || store.isImporting)
    }
    @ViewBuilder private var cropInstruction: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: 8) {
                Text("Crop \(model.pageIndex + 1)").font(.headline)
                    .accessibilityLabel("Crop page \(model.pageIndex + 1)")
                Spacer(minLength: 0)
                Button { cropHelp = true } label: {
                    Image(systemName: "questionmark.circle").frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Crop help")
            }.foregroundStyle(Theme.accent).padding(12).liquidGlass(cornerRadius: 20)
                .frame(maxWidth: 860).padding(.horizontal, 16)
        } else {
            HStack(spacing: 8) {
                Label("Drag to position. Pinch to enlarge. Keep every marking in view.", systemImage: "crop")
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text("Page \(model.pageIndex + 1)").font(.caption.weight(.semibold))
            }.padding(16).liquidGlass(cornerRadius: 20)
                .frame(maxWidth: 860).padding(.horizontal, 16)
        }
    }
    private var seekBookmarkLabel: String? {
        model.currentScore?.bookmarks.filter { $0.startPage <= Int(seekValue) }.max { $0.startPage < $1.startPage }?.title
    }
    private var cropControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Button { cropAdjustments = true } label: { Label("Adjust", systemImage: "slider.horizontal.3") }
                        .buttonStyle(GlassActionStyle()).accessibilityLabel("Adjust crop")
                    Button("Save") { model.saveCrop() }
                        .buttonStyle(GlassActionStyle(prominent: true)).accessibilityLabel("Save crop")
                    Button("Reset") { model.resetCrop() }
                        .buttonStyle(GlassActionStyle()).accessibilityLabel("Reset margins")
                    Button("Cancel") { model.cancelCrop() }.buttonStyle(GlassActionStyle())
                }
            } else {
                VStack(spacing: 8) {
                    cropSlider("Straighten page", value: $model.layout.rotation, range: -10...10,
                               step: 0.1, display: String(format: "%.1f°", model.layout.rotation))
                        .padding(14).liquidGlass(cornerRadius: 20)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Button("Adjust") { cropAdjustments = true }.accessibilityLabel("Adjust crop")
                            Button("Cancel") { model.cancelCrop() }
                            Button("Reset") { model.resetCrop() }.accessibilityLabel("Reset margins")
                            Spacer(minLength: 0)
                            Button("Save crop") { model.saveCrop() }.buttonStyle(GlassActionStyle(prominent: true))
                        }.buttonStyle(GlassActionStyle())
                        VStack(spacing: 8) {
                            HStack {
                                Button("Adjust") { cropAdjustments = true }.accessibilityLabel("Adjust crop")
                                Spacer(minLength: 0)
                                Button("Save crop") { model.saveCrop() }
                                    .buttonStyle(GlassActionStyle(prominent: true))
                            }
                            HStack {
                                Button("Reset") { model.resetCrop() }.accessibilityLabel("Reset margins")
                                Spacer(minLength: 0)
                                Button("Cancel") { model.cancelCrop() }
                            }
                        }.buttonStyle(GlassActionStyle())
                    }
                }
            }
        }.frame(maxWidth: 860).padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var cropAdjustmentsPanel: some View {
        NavigationStack {
            Form {
                Section("Crop adjustments") {
                    cropSlider("Straighten page", value: $model.layout.rotation, range: -10...10,
                               step: 0.1, display: String(format: "%.1f°", model.layout.rotation))
                    cropSlider("Crop scale", value: $model.layout.scale, range: 1...3,
                               step: 0.05, display: String(format: "%.0f%%", model.layout.scale * 100))
                    cropSlider("Move page horizontally", value: $model.layout.offsetX, range: -1...1,
                               step: 0.01, display: String(format: "%+.0f%%", model.layout.offsetX * 100))
                    cropSlider("Move page vertically", value: $model.layout.offsetY, range: -1...1,
                               step: 0.01, display: String(format: "%+.0f%%", model.layout.offsetY * 100))
                }
            }.percuscorePanel()
                .navigationTitle("Adjust crop")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { cropAdjustments = false }
                } }
        }.percuscoreSheet().presentationDetents([.large])
    }

    private func cropSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.subheadline); Spacer(minLength: 8); Text(display).font(.caption.monospacedDigit()) }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title).accessibilityValue(display)
        }
    }
}


/// Shared by the full reader and page navigator so recovery remains reachable in either view.
struct NavigationRecoveryNotice: View {
    @ObservedObject var model: ReaderModel
    var recovered: () -> Void = {}

    var body: some View {
        if let failure = model.navigationFailure {
            VStack(alignment: .leading, spacing: 8) {
                Text("Page unavailable").font(.headline)
                Text(failure.message).font(.caption).lineLimit(4)
                if failure.canIgnoreMarkings {
                    Button("Open without markings (read only)") {
                        if model.ignoreFailedMarkings() { recovered() }
                    }.frame(minHeight: 44)
                }
                if model.canSkipFailedPage {
                    Button("Skip this page") { if model.skipFailedPage() { recovered() } }.frame(minHeight: 44)
                }
                Button("Stay on current page") { model.clearNavigationFailure() }.frame(minHeight: 44)
            }.padding(16).frame(maxWidth: 540, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.primary).tint(Theme.accent)
        } else if model.ignoringMarkings {
            Text("Read only · Markings hidden; original files preserved")
                .font(.caption).padding(12).background(Theme.surface, in: Capsule())
                .foregroundStyle(.primary).allowsHitTesting(false)
        }
    }
}
