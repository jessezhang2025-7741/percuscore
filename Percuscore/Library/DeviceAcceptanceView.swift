import SwiftUI
import UIKit

private extension AcceptanceOutcome {
    var label: String { switch self { case .notRun: "Not run"; case .passed: "Passed"; case .failed: "Failed" } }
}

@MainActor
struct DeviceAcceptanceView: View {
    @StateObject private var coordinator: DeviceAcceptanceCoordinator
    @ObservedObject private var diagnostics = ReaderDiagnostics.shared
    @State private var showingLibrary = false
    @State private var newRun = false
    @State private var rebuild = false
    @State private var exported: AcceptanceExport?
    @State private var exportDirectory: URL?
    init() { _coordinator = StateObject(wrappedValue: .shared) }
    init(coordinator: DeviceAcceptanceCoordinator) { _coordinator = StateObject(wrappedValue: coordinator) }

    var body: some View {
        Form {
            Section("This run") {
                LabeledContent("Result", value: coordinator.report.status.rawValue.capitalized)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Acceptance result")
                    .accessibilityValue(coordinator.report.status.rawValue.capitalized)
                    .accessibilityIdentifier("acceptance-status")
                LabeledContent("Device", value: coordinator.report.deviceModel)
                LabeledContent("System", value: coordinator.report.systemVersion)
                LabeledContent("App", value: "\(coordinator.report.build.version) (\(coordinator.report.build.build))")
                Text("Source: \(coordinator.report.build.commit.isEmpty ? "Unavailable" : coordinator.report.build.commit) · \(coordinator.report.build.sourceState)")
                    .font(.caption).textSelection(.enabled)
                if coordinator.report.isSimulator { Text("Simulator run — cannot pass physical-device acceptance.").foregroundStyle(.secondary) }
                if !coordinator.report.build.traceable { Text("A clean committed build is required for completed device acceptance.").foregroundStyle(.secondary) }
                if !coordinator.matchesCurrentBuild { Text("This record belongs to an earlier build. Export it or start a new run for the installed version.").foregroundStyle(.red) }
                if !coordinator.matchesCurrentEnvironment { Text("This record belongs to a different device or system version. Start a new run for this environment.").foregroundStyle(.red) }
            }
            Section("Operator") {
                TextField("Your name", text: field(\.operatorName)).accessibilityIdentifier("acceptance-operator")
                TextField("Pencil model", text: field(\.pencilModel)).accessibilityIdentifier("acceptance-pencil")
            }.disabled(!coordinator.canEdit)
            Section("Isolated test library") {
                Text("Four-page practice, rotated pages, saved crop and ink, a 120-page 300-dpi scan, and a cross-work setlist. Your regular library stays separate.")
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.working {
                    ProgressView(value: Double(coordinator.progress), total: 120)
                    Text("Preparing scan page \(coordinator.progress) / 120… Keep this app open.").font(.caption)
                } else {
                    Button(coordinator.report.fixtureManifestSHA256 == nil ? "Prepare test library" : "Verify test library") { coordinator.prepareLibrary() }
                        .disabled(!coordinator.canEdit)
                    Button("Open test library") { showingLibrary = true }
                        .disabled(coordinator.library == nil || !coordinator.canEdit)
                    Button("Rebuild test library…", role: .destructive) { rebuild = true }.disabled(!coordinator.canEdit)
                }
                Text("Preparation enables local diagnostics. First preparation can take a few minutes and uses about 270 MB. Results are saved separately from the test scores.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Manual observations") {
                NavigationLink {
                    AcceptanceChecksView(coordinator: coordinator, repetitions: true)
                } label: {
                    LabeledContent("Input chain · 30 repetitions", value: "\(coordinator.report.checks.filter { $0.id.hasPrefix("input-") && $0.outcome == .passed }.count) / 30")
                }.accessibilityIdentifier("acceptance-input-chain")
                NavigationLink("Lifecycle and gestures") { AcceptanceChecksView(coordinator: coordinator, repetitions: false) }
                NavigationLink("30–60 minute rehearsal") { AcceptanceRehearsalView(coordinator: coordinator) }
                TextField("Problem reproduction steps", text: field(\.issueSteps, limit: 4000), axis: .vertical).lineLimit(3...8)
                Text("Mark each item after observing it. A failure remains in this run's history; start a new run after a fix. No controls automatically confirm Pencil or rehearsal quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!coordinator.canEdit)
            Section("Local diagnostics") {
                Toggle("Record reader diagnostics", isOn: $diagnostics.enabled)
                Text("Up to 512 events / 256 KiB; old events roll off. Only operation, state, page and timing metadata. No score names, PDF content or handwriting content.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = diagnostics.storageError { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Export report and diagnostics") {
                    do {
                        let urls = try coordinator.export(diagnostics: diagnostics)
                        exportDirectory = urls[0].deletingLastPathComponent()
                        exported = AcceptanceExport(urls: urls)
                    }
                    catch { coordinator.error = error.localizedDescription }
                }.disabled(coordinator.working)
                Button("Start a new acceptance run…") { newRun = true }.disabled(coordinator.working)
                Text("Export includes your notes, device/build details and diagnostic metadata. The local share sheet lets you choose where to save it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .percuscorePanel()
        .navigationTitle("Device acceptance")
        .fullScreenCover(isPresented: $showingLibrary) {
            if let store = coordinator.library { LibraryView().environmentObject(store).tint(Theme.accent) }
        }
        .sheet(item: $exported, onDismiss: cleanupExport) { item in AcceptanceShareSheet(urls: item.urls) }
        .alert("Start a new run?", isPresented: $newRun) {
            Button("Start new run") { coordinator.newRun() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The previous record is preserved locally. New observations start as not run. The test library is retained.") }
        .alert("Rebuild the test library?", isPresented: $rebuild) {
            Button("Rebuild", role: .destructive) { if coordinator.newRun() { coordinator.prepareLibrary(rebuild: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Starts a new run and replaces only the test library's scores and markings. Your previous report and regular library are preserved.") }
        .alert("Device acceptance", isPresented: Binding(get: { coordinator.error != nil }, set: { if !$0 { coordinator.error = nil } })) {
            Button("OK") { coordinator.error = nil }
        } message: { Text(coordinator.error ?? "") }
    }
    private func field(_ key: WritableKeyPath<DeviceAcceptanceReport, String>, limit: Int = 200) -> Binding<String> {
        Binding(get: { coordinator.report[keyPath: key] }, set: { value in coordinator.update { $0[keyPath: key] = String(value.prefix(limit)) } })
    }
    private func cleanupExport() {
        // Each share uses its own folder; the report itself remains in session.json.
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
        exported = nil
    }
}

private struct AcceptanceChecksView: View {
    @ObservedObject var coordinator: DeviceAcceptanceCoordinator
    let repetitions: Bool
    var body: some View {
        Form {
            if repetitions {
                Section { Text("Pencil first stroke → continuous writing → Done → tap existing ink → turn → return → annotate again. Repeat 30 times. Check for lost first strokes, freezes, unwanted turns and misplaced ink.") }
            }
            ForEach(coordinator.report.checks.filter { $0.id.hasPrefix("input-") == repetitions }) { check in
                NavigationLink {
                    AcceptanceCheckView(coordinator: coordinator, id: check.id)
                } label: { LabeledContent(check.title, value: check.outcome.label) }
                    .accessibilityIdentifier("acceptance-check-" + check.id)
            }
        }.percuscorePanel().navigationTitle(repetitions ? "Input repetitions" : "Lifecycle & gestures")
    }
}

private struct AcceptanceCheckView: View {
    @ObservedObject var coordinator: DeviceAcceptanceCoordinator
    let id: String
    private var check: AcceptanceCheck { coordinator.report.checks.first { $0.id == id }! }
    var body: some View {
        Form {
            Section {
                Picker("Observed result", selection: Binding(get: { check.outcome }, set: { value in coordinator.update { $0.record(id: id, outcome: value, notes: check.notes) } })) {
                    ForEach(AcceptanceOutcome.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Notes and reproduction steps", text: Binding(get: { check.notes }, set: { value in coordinator.update { $0.record(id: id, outcome: check.outcome, notes: value) } }), axis: .vertical)
                    .lineLimit(4...12)
                if check.everFailed { Text("A failure was recorded in this run and remains part of its result.").foregroundStyle(.red) }
            }
        }.percuscorePanel().navigationTitle(check.title).disabled(!coordinator.canEdit)
    }
}

private struct AcceptanceRehearsalView: View {
    @ObservedObject var coordinator: DeviceAcceptanceCoordinator
    var body: some View {
        Form {
            Section {
                Text("Play the cross-work test setlist for 30–60 minutes. Check freezes, accidental page turns, first-stroke loss and misplaced ink. Timing alone does not confirm a pass.")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = coordinator.report.rehearsalStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? coordinator.report.rehearsalDurationSeconds
                    LabeledContent("Elapsed rehearsal", value: "\(Int(seconds) / 60)m \(Int(seconds) % 60)s")
                }
                if coordinator.report.rehearsalStartedAt == nil {
                    Button("Start rehearsal timer") { coordinator.update { $0.startRehearsal() } }
                } else { Button("Stop rehearsal timer") { coordinator.update { $0.stopRehearsal() } } }
                if coordinator.report.rehearsalInterrupted { Text("The app process ended while timing. Start a fresh rehearsal timer; closed-app time was not counted.").foregroundStyle(.secondary) }
                Picker("Rehearsal result", selection: Binding(get: { coordinator.report.rehearsalOutcome }, set: { value in
                    coordinator.update { $0.rehearsalOutcome = value }
                })) { ForEach(AcceptanceOutcome.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                TextField("Rehearsal notes", text: Binding(get: { coordinator.report.rehearsalNotes }, set: { value in coordinator.update { $0.rehearsalNotes = String(value.prefix(4000)) } }), axis: .vertical).lineLimit(4...10)
                Text("At least 30 timed minutes plus your explicit pass observation are required. A killed process interrupts this attempt.").font(.caption).foregroundStyle(.secondary)
            }
        }.percuscorePanel().navigationTitle("Rehearsal").disabled(!coordinator.canEdit)
    }
}

private struct AcceptanceExport: Identifiable { let id = UUID(); let urls: [URL] }
private struct AcceptanceShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
