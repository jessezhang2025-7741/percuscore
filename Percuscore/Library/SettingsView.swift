import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var diagnostics = ReaderDiagnostics.shared
    var allowsBackup = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Pencil") {
                    Toggle("Automatically enter annotation mode", isOn: setting(\.pencilAutoAnnotate))
                    Toggle("Prevent finger drawing", isOn: setting(\.preventFingerDrawing))
                    Text("With finger drawing prevented, use Pencil for ink and fingers for page turns and zoom.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Performance") {
                    Toggle("Half-page turns", isOn: setting(\.halfPageTurns))
                    Toggle("Continue to next setlist item", isOn: setting(\.continueSetlist))
                    Toggle("Step through landscape pages", isOn: setting(\.landscapeSteps))
                    Toggle("Keep screen awake while reading", isOn: setting(\.keepScreenAwake))
                    Text("Half-page turns are available when a full page fits. Landscape steps show the top, then the bottom.").font(.caption).foregroundStyle(.secondary)
                }
                if allowsBackup {
                    Section("Backup & restore") {
                        NavigationLink {
                            BackupView().environmentObject(store)
                        } label: { Label("Library backup", systemImage: "externaldrive") }
                        Text("Save PDFs, markings, score details, bookmarks and setlists together.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Your library") {
                    if allowsBackup {
                        NavigationLink("Recently Deleted") { RecentlyDeletedView().environmentObject(store) }
                        NavigationLink("Storage management") { StorageManagementView().environmentObject(store) }
                    }
                    Label("Stored on this iPad", systemImage: "ipad")
                    Text("PDFs are copied into Percuscore. Ink, crop and bookmarks are saved separately. There is no automatic cloud sync.")
                    Text("Save a library backup outside this app. Deleting the app can delete its local library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Device acceptance & diagnostics") {
                    if !store.isAcceptanceLibrary {
                        NavigationLink("Device acceptance") { DeviceAcceptanceView() }
                    }
                    Toggle("Record reader diagnostics", isOn: $diagnostics.enabled)
                    Text("Optional local metadata only. Up to 512 events / 256 KiB; no PDF or handwriting content. Export from Device acceptance.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear diagnostic log", role: .destructive) { diagnostics.clear() }
                    if let error = diagnostics.storageError { Text(error).foregroundStyle(.red) }
                }
                Section("Percuscore") {
                    Text("A quiet place to prepare, rehearse and perform.").font(.body)
                    LabeledContent("Version", value: versionLabel)
                    LabeledContent("Source", value: sourceLabel)
                    ShareLink(item: versionDetails) {
                        Label("Share version details", systemImage: "square.and.arrow.up")
                    }
                    Text("Include version details when reporting a problem.")
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
            .interactiveDismissDisabled(store.isManagingLibrary)
            .percuscorePanel()
            .navigationTitle("Reader settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(store.isManagingLibrary) } }
        }.percuscoreSheet()
    }
    private func setting(_ key: WritableKeyPath<ReaderSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.index.settings[keyPath: key] }, set: { value in store.update { $0.settings[keyPath: key] = value } })
    }
    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
    private var buildInfo: [String: String] {
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return info.compactMapValues { $0 as? String }
    }
    private var sourceLabel: String {
        guard let commit = buildInfo["commit"], !commit.isEmpty else { return "Unavailable" }
        let suffix = buildInfo["source_state"] == "clean" ? "" : " · Modified source"
        return String(commit.prefix(12)) + suffix
    }
    private var versionDetails: String {
        let commit = buildInfo["commit"].flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable"
        return "Percuscore \(versionLabel)\nSource: \(commit)\nState: \(buildInfo["source_state"] ?? "unavailable")"
    }
}
