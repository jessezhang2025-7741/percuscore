import SwiftUI
import UIKit

struct BackupPracticeSession: Identifiable {
    let id = UUID()
    let store: LibraryStore
}

struct BackupPracticeView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var scores = false
    var body: some View {
        NavigationStack {
            BackupView().environmentObject(store)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close practice") { dismiss() }.disabled(store.isManagingLibrary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Open practice scores") { scores = true }.disabled(store.isManagingLibrary)
                    }
                }
        }
        .interactiveDismissDisabled(store.isManagingLibrary)
        .fullScreenCover(isPresented: $scores) { LibraryView().environmentObject(store).tint(Theme.accent) }
    }
}

struct BackupVerificationDetailsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var restored: BackupPracticeSession?
    @State private var report: BackupReportShare?
    @State private var reportDirectory: URL?
    @State private var removing = false
    @State private var error: String?
    private var editable: Bool {
        store.backupRecords.verification.map(BackupVerificationService.matchesCurrentEnvironment) == true && !store.isManagingLibrary
    }
    var body: some View {
        Form {
            if let evidence = store.backupRecords.verification {
                Section("Automatic content verification") {
                    Label("Restored, reopened and compared", systemImage: "checkmark.circle")
                    Text(evidence.verification.verifiedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("File SHA-256: " + evidence.verification.archiveSHA256).font(.caption).textSelection(.enabled)
                    Text("\(evidence.verification.scoreCount) scores · \(evidence.verification.setlistCount) setlists · \(evidence.verification.savedInkCount) saved ink pages · \(evidence.verification.draftCount) drafts")
                    if let count = evidence.verification.deletedScoreCount, let bytes = evidence.verification.deletedAssetBytes {
                        Text("Recently Deleted: \(count) scores · \(storageSize(bytes))")
                    }
                    Text("App \(evidence.build.version) (\(evidence.build.build)) · \(evidence.deviceModel) · iOS \(evidence.systemVersion)").font(.caption)
                    Text("Commit: " + evidence.build.commit).font(.caption).textSelection(.enabled)
                    Button("Open isolated restored library") {
                        if let root = store.verifiedBackupRoot {
                            restored = BackupPracticeSession(store: LibraryStore(root: root, isolationLabel: "BACKUP VERIFICATION · ISOLATED RESTORED COPY"))
                        }
                    }.disabled(store.verifiedBackupRoot == nil)
                    Text("Inspect saved markings before recovering the draft. Changes here affect only this disposable copy. The regular library and selected backup stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Physical Files and visual checks") {
                    Text("Result: " + evidence.physicalFilesStatus.rawValue)
                    if evidence.isSimulator { Text("Simulator run. Physical Files acceptance remains incomplete.").foregroundStyle(.secondary) }
                    if evidence.exportedAt == nil { Text("No completed system export was recorded for this exact file. Verify a file exported from this library to record the full Files round trip.").font(.caption) }
                    if !editable { Text("This record belongs to another build, device or system. Verify the selected file again to start a new record.").foregroundStyle(.secondary) }
                    Toggle("Saved outside this App's data directory", isOn: Binding(get: { evidence.outsideAppConfirmed }, set: { value in store.updateBackupVisual { $0.outsideAppConfirmed = value } }))
                        .disabled(!editable)
                    ForEach(evidence.visualChecks) { check in
                        NavigationLink {
                            BackupVisualCheckView(id: check.id).environmentObject(store)
                        } label: { LabeledContent(check.title, value: check.outcome.backupLabel) }
                    }
                    TextField("Export location and reproduction notes", text: Binding(get: { evidence.notes }, set: { value in store.updateBackupVisual { $0.notes = String(value.prefix(4000)) } }), axis: .vertical)
                        .lineLimit(3...8).disabled(!editable)
                    Text("Choose results only after inspecting the restored copy. A failure stays in this record. Verification again starts a fresh record.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Export backup verification report") {
                        do {
                            let urls = try BackupVerificationService.exportReport(evidence)
                            reportDirectory = urls.first?.deletingLastPathComponent()
                            report = BackupReportShare(urls: urls)
                        } catch { self.error = error.localizedDescription }
                    }
                    Button("Remove verification copies…", role: .destructive) { removing = true }
                    Text("Inspection copies use local storage. Removing them keeps reports, original backups and regular scores.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.backupEvidenceError { Section { Text(error).foregroundStyle(.red) } }
        }
        .percuscorePanel().navigationTitle("Backup verification")
        .fullScreenCover(item: $restored) { session in LibraryView().environmentObject(session.store).tint(Theme.accent) }
        .sheet(item: $report, onDismiss: {
            if let reportDirectory { try? FileManager.default.removeItem(at: reportDirectory) }
            reportDirectory = nil
        }) { item in BackupReportSheet(urls: item.urls) }
        .alert("Remove inspection copies?", isPresented: $removing) {
            Button("Remove copies", role: .destructive) {
                do { try store.removeVerificationCopies() } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deletes only isolated restoration copies and any edits made inside them. Your reports, selected backups and regular library are kept.") }
        .alert("Backup verification", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct BackupVisualCheckView: View {
    @EnvironmentObject private var store: LibraryStore
    let id: String
    var body: some View {
        Form {
            if let record = store.backupRecords.verification, let check = record.visualChecks.first(where: { $0.id == id }) {
                Section {
                    Text(check.title).font(.headline)
                    Picker("Observed result", selection: Binding(get: { check.outcome }, set: { value in
                        store.updateBackupVisual { $0.recordVisual(id: id, outcome: value, notes: check.notes) }
                    })) {
                        ForEach(AcceptanceOutcome.allCases, id: \.self) { Text($0.backupLabel).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("Observations and reproduction steps", text: Binding(get: { check.notes }, set: { value in
                        store.updateBackupVisual { $0.recordVisual(id: id, outcome: check.outcome, notes: value) }
                    }), axis: .vertical).lineLimit(4...12)
                    if check.everFailed { Text("A failure remains recorded for this verification.").foregroundStyle(.red) }
                }.disabled(!BackupVerificationService.matchesCurrentEnvironment(record))
            }
        }.percuscorePanel().navigationTitle("Visual observation")
    }
}

private extension AcceptanceOutcome {
    var backupLabel: String {
        switch self { case .notRun: return "Not run"; case .passed: return "Passed"; case .failed: return "Failed" }
    }
}
private struct BackupReportShare: Identifiable { let id = UUID(); let urls: [URL] }
private struct BackupReportSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
