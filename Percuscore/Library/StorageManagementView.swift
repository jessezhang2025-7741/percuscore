import SwiftUI

func storageSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

struct RecentlyDeletedView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var confirming: Score?
    private var scores: [Score] { store.index.deletedScores.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) } }
    private var busy: Bool { store.isManagingLibrary || store.isImporting || !store.isReady }

    var body: some View {
        Form {
            Section {
                Text("Scores stay here until you restore or permanently delete them. There is no automatic expiry.")
                Text("Setlists keep their positions and skip these scores during performance. Restoring a score makes its references available again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recently Deleted · \(scores.count)") {
                if scores.isEmpty { Text("No recently deleted scores").foregroundStyle(.secondary) }
                ForEach(scores) { score in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(score.title).font(.headline)
                        if let date = score.deletedAt { Text("Deleted " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        if let bytes = store.storageUsage?.scoreBytes[score.id] {
                            Text(storageSize(bytes)).font(.caption).foregroundStyle(.secondary)
                        }
                        if score.purgePendingAt != nil {
                            Text("Cleanup pending. Some files may already have been removed. Retry to finish permanent deletion.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 20) { actions(score) }
                            VStack(alignment: .leading, spacing: 12) { actions(score) }
                        }
                    }.padding(.vertical, 6)
                }
            }
            Section {
                storageStatus
                Button("Refresh storage") { Task { await store.refreshStorage() } }
                    .disabled(store.isCalculatingStorage || busy)
                NavigationLink("Storage management") { StorageManagementView().environmentObject(store) }
            }
        }
        .navigationTitle("Recently Deleted")
        .percuscorePanel()
        .task { await store.refreshStorage() }
        .onChange(of: store.index) { _, _ in Task { await store.refreshStorage() } }
        .alert("Permanently delete 1 score?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Permanently delete", role: .destructive) {
                guard let id = confirming?.id else { return }
                confirming = nil
                Task { _ = await store.deletePermanently(id); await store.refreshStorage() }
            }
        } message: {
            if let score = confirming {
                let references = store.index.setlists.flatMap(\.entries).filter { $0.scoreID == score.id }.count
                Text("‘\(score.title)’: PDF, saved markings, drafts, crops, views and bookmarks will be erased. \(references) setlist references will be removed. Estimated file space: \(storageSize(store.storageUsage?.scoreBytes[score.id] ?? 0)). This cannot be undone here; an earlier external backup is needed to recover it.")
            }
        }
        .alert("Could not finish", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    @ViewBuilder private func actions(_ score: Score) -> some View {
        Button("Restore") { _ = store.restoreDeletedScore(score.id) }
            .accessibilityLabel("Restore \(score.title)")
            .buttonStyle(.borderless)
            .disabled(busy || score.purgePendingAt != nil)
        Button(score.purgePendingAt == nil ? "Permanently delete…" : "Retry cleanup…", role: .destructive) { confirming = score }
            .accessibilityLabel(score.purgePendingAt == nil ? "Permanently delete \(score.title)" : "Retry cleanup for \(score.title)")
            .buttonStyle(.borderless)
            .disabled(busy || store.storageUsage == nil || store.isCalculatingStorage)
    }
    @ViewBuilder private var storageStatus: some View {
        if store.isManagingLibrary { ProgressView("Finishing library operation…") }
        if store.isCalculatingStorage { ProgressView("Calculating storage…") }
        if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

struct StorageManagementView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var clearing = false
    var body: some View {
        Form {
            Section("Local storage") {
                if store.isCalculatingStorage { ProgressView("Calculating storage…") }
                if let usage = store.storageUsage {
                    LabeledContent("PDFs", value: storageSize(usage.pdfBytes))
                    LabeledContent("Saved markings", value: storageSize(usage.savedInkBytes))
                    LabeledContent("Drafts", value: storageSize(usage.draftBytes))
                    LabeledContent("Drawing metadata", value: storageSize(usage.metadataBytes))
                    LabeledContent("Cache", value: storageSize(usage.cacheBytes))
                    LabeledContent("Retained files to inspect", value: storageSize(usage.retainedBytes))
                    LabeledContent("Indexes, reports & local copies", value: storageSize(usage.otherBytes))
                    LabeledContent("Total file size", value: storageSize(usage.totalBytes))
                    LabeledContent("Recently Deleted (included above)", value: storageSize(usage.recentlyDeletedBytes))
                    Text("Calculated " + usage.calculatedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                } else if !store.isCalculatingStorage { Text("Storage has not been calculated.") }
                if let error = store.storageError { Text(error).foregroundStyle(.red) }
                Button("Refresh storage") { Task { await store.refreshStorage() } }
                    .disabled(store.isCalculatingStorage || store.isManagingLibrary || !store.isReady)
                Text("File sizes are estimates of space that may be freed. Recently Deleted is a subset of the categories above. Setlists reference the same files and do not duplicate PDFs. Local backup inspection and practice copies appear under local copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Safe cleanup") {
                NavigationLink("Recently Deleted") { RecentlyDeletedView().environmentObject(store) }
                Button("Clear cache…") { clearing = true }
                    .disabled(store.isManagingLibrary || store.isImporting || !store.isReady)
                Text("Clears library thumbnail memory and designated disk cache files. PDFs, saved markings, drafts and retained files are preserved. Open-reader previews are released when the reader closes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Retained files to inspect") {
                Text("Older removals may have left files without library records. Titles, bookmarks and setlist positions cannot be reconstructed from these files alone. Nothing here is automatically erased.")
                    .font(.caption).foregroundStyle(.secondary)
                if let usage = store.storageUsage {
                    Text("\(usage.retainedFiles.count) files · \(storageSize(usage.retainedBytes))")
                    DisclosureGroup("Show retained filenames") {
                        ForEach(Array(usage.retainedFiles.prefix(100))) { file in
                            VStack(alignment: .leading) {
                                Text(file.relativePath).font(.caption).textSelection(.enabled)
                                Text(storageSize(file.bytes)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if usage.retainedFiles.count > 100 { Text("Showing the first 100. All files are included in the total.").font(.caption) }
                    }
                }
            }
        }.navigationTitle("Storage management").percuscorePanel()
            .task { await store.refreshStorage() }
            .onChange(of: store.index) { _, _ in Task { await store.refreshStorage() } }
            .alert("Clear cache?", isPresented: $clearing) {
                Button("Cancel", role: .cancel) {}
                Button("Clear cache") { Task { await store.clearLibraryCache() } }
            } message: { Text("Cached library thumbnails can be recreated. Your scores, markings and drafts stay intact.") }
            .alert("Could not finish", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
}
