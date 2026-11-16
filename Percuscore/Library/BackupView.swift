import SwiftUI
import UniformTypeIdentifiers
import UIKit

extension UTType {
    static let percuscoreBackup = UTType(exportedAs: "com.percuscore.library-backup", conformingTo: .data)
}

private struct BackupExport: Identifiable {
    let id = UUID()
    let url: URL
    let sha256: String
}

struct BackupView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var importing = false
    @State private var verifying = false
    @State private var practice: BackupPracticeSession?
    @State private var confirmingRestore = false
    @State private var export: BackupExport?
    @State private var pendingRestore: URL?
    @State private var message: String?
    @State private var working = false
    @State private var operation = ""

    var body: some View {
        Form {
            Section {
                Text("Your whole rehearsal folder")
                    .font(.title2.bold())
                Text("A single backup includes your PDFs, saved markings and drafts, page crops, bookmarks, setlists, score details and pen presets.")
                Text("Recently Deleted is included, with its deletion dates. Pending permanent cleanup must be retried before creating a backup.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Save it in a location outside Percuscore before changing iPads or deleting the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Create a backup") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Last successful export", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                    if let date = store.lastBackupExportAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Backup export time")
                            .accessibilityValue(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text(store.backupHistoryUnavailable ? "Export time unavailable" : "No export recorded")
                            .foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Button { create() } label: {
                    Label("Export library backup", systemImage: "square.and.arrow.up")
                }.buttonStyle(GlassActionStyle()).padding(.vertical, 4)
                    .disabled(working || store.isImporting || store.isManagingLibrary || !store.isReady)
                Text("The backup is a snapshot. Future edits are included only when you make a new backup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup evidence") {
                backupEvent("File generated", event: store.backupRecords.prepared)
                backupEvent("System export completed", event: store.backupRecords.exported)
                if let evidence = store.backupRecords.verification {
                    NavigationLink("File passed restore verification") {
                        BackupVerificationDetailsView().environmentObject(store)
                    }
                    Text("Verified file: " + String(evidence.verification.archiveSHA256.prefix(12))).font(.caption).foregroundStyle(.secondary)
                } else { Text("Restore verification: Not run") }
                Button("Choose backup to verify") { verifying = true; importing = true }
                    .disabled(working || store.isImporting || store.isManagingLibrary || !store.isReady)
                Text("Verification restores the selected file to a separate library, reopens it and compares all content. Visual and physical Files checks are recorded separately.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.backupEvidenceError { Text(error).foregroundStyle(.red) }
                if let warning = store.restoreRecoveryWarning { Text(warning).foregroundStyle(.orange) }
            }
            if !store.isAcceptanceLibrary {
                Section("Practice safely") {
                    Button("Prepare standard test library") { preparePractice() }.disabled(working || store.isManagingLibrary || !store.isReady)
                    Text("Two synthetic works with multicolor saved ink, an unfinished draft, crops, zoom positions, bookmarks and a repeated cross-work setlist. Export and verify these in a separate practice library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Restore a backup") {
                Button { verifying = false; importing = true } label: {
                    Label("Choose backup to restore", systemImage: "square.and.arrow.down")
                }.buttonStyle(GlassActionStyle()).padding(.vertical, 4)
                    .disabled(working || store.isImporting || store.isManagingLibrary || !store.isReady)
                Text("Restored scores and setlists are added to this library. Existing scores stay unchanged. Restoring the same backup again creates another copy.")
                Text("If checking fails, keep the original backup for recovery. It stays unchanged and nothing is added to your library.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("On an empty library, reading settings and pen presets are restored too. Otherwise your current settings are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if working {
                Section { HStack { ProgressView(); Text(operation) } }
            }
        }
        .percuscorePanel()
        .navigationTitle("Library backup")
        .navigationBarBackButtonHidden(working)
        .interactiveDismissDisabled(working || export != nil)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.percuscoreBackup]) { result in
            switch result {
            case .success(let url):
                if verifying { verify(url) }
                else { pendingRestore = url; confirmingRestore = true }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog("Add this backup to your library?", isPresented: $confirmingRestore,
                            titleVisibility: .visible, presenting: pendingRestore) { url in
            Button("Restore and add to library") {
                restore(url)
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { _ in
            Text("Current scores stay unchanged. Restoring twice creates duplicates. The backup is checked before anything is added.")
        }
        .sheet(item: $export, onDismiss: cleanupExport) { item in
            BackupFileExporter(url: item.url) { saved in
                do {
                    try store.completeBackupExport(saved: saved, archiveSHA256: item.sha256)
                    message = saved ? "System export completed. Keep the file outside Percuscore, then choose that saved file to verify its restoration." : "Export cancelled."
                } catch {
                    message = "Backup exported, but its record could not be saved. Your previous export record was kept. \(error.localizedDescription)"
                }
                export = nil
            }.interactiveDismissDisabled()
        }
        .fullScreenCover(item: $practice) { session in
            BackupPracticeView(store: session.store)
        }
        .alert("Library backup", isPresented: Binding(get: { message != nil && export == nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    @State private var temporaryExport: URL?
    private func cleanupExport() {
        if let temporaryExport { try? FileManager.default.removeItem(at: temporaryExport.deletingLastPathComponent()) }
        temporaryExport = nil
    }
    private func create() {
        working = true; operation = "Preparing your backup…"
        Task {
            defer { working = false }
            do {
                let prepared = try await store.createBackupFile()
                temporaryExport = prepared.url; export = BackupExport(url: prepared.url, sha256: prepared.sha256)
            } catch { message = error.localizedDescription }
        }
    }
    @ViewBuilder
    private func backupEvent(_ title: String, event: BackupFileEvent?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if let event {
                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                Text("File: " + String(event.sha256.prefix(12))).font(.caption)
                if let count = event.deletedScoreCount, let bytes = event.deletedAssetBytes {
                    Text("Recently Deleted: \(count) scores · \(storageSize(bytes))").font(.caption)
                }
            } else { Text("Not recorded") }
        }.foregroundStyle(.secondary)
    }
    private func verify(_ url: URL) {
        working = true; operation = "Restoring, reopening and comparing the selected file…"
        Task {
            defer { working = false }
            do {
                _ = try await store.verifyBackup(from: url)
                message = "The selected file passed restore verification. Open its verification details to inspect the isolated copy and record visual checks."
            } catch { message = error.localizedDescription }
        }
    }
    private func preparePractice() {
        guard let disk = store.disk else { return }
        working = true; operation = "Preparing isolated practice scores…"
        Task {
            defer { working = false }
            let root = disk.root.appendingPathComponent(".backup-practice/" + UUID().uuidString)
            do {
                try await Task.detached(priority: .userInitiated) { try BackupPracticeLibrary.build(at: root) }.value
                practice = BackupPracticeSession(store: LibraryStore(root: root, isolationLabel: "BACKUP PRACTICE · ISOLATED TEST SCORES"))
            } catch { try? FileManager.default.removeItem(at: root); message = error.localizedDescription }
        }
    }
    private func restore(_ url: URL) {
        working = true; operation = "Checking and restoring your backup…"
        Task {
            defer { working = false }
            do {
                let count = try await store.restoreBackup(from: url)
                message = "Restored \(count) scores and their setlists. Existing scores were kept."
            } catch { message = error.localizedDescription }
        }
    }
}

struct BackupFileExporter: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        private var finished = false
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        private func finish(saved: Bool) {
            guard !finished else { return }
            finished = true; completion(saved)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(saved: !urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(saved: false) }
    }
}
