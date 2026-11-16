import SwiftUI
import UIKit

private struct SharedPDF: Identifiable {
    let id = UUID()
    let url: URL
}

struct PDFExportView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let score: Score
    @State private var working = false
    @State private var shared: SharedPDF?
    @State private var temporary: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(score.title).font(.headline)
                    Text("Export the complete score (\(score.pageCount) pages).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Button { prepare(marked: false) } label: {
                        Label("Original PDF", systemImage: "doc")
                    }.buttonStyle(GlassActionStyle()).padding(.vertical, 4)
                    Text("An unchanged copy of the imported PDF.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button { prepare(marked: true) } label: {
                        Label("PDF with saved markings", systemImage: "pencil.and.outline")
                    }.buttonStyle(GlassActionStyle()).padding(.vertical, 4)
                    Text("Includes saved Percuscore markings, even when hidden in the reader. Unconfirmed drafts are not included.")
                    Text("Exports full pages without the reader's Crop. Markings are flattened in the exported copy; your editable ink stays in Percuscore.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if working { Section { HStack { ProgressView(); Text("Preparing PDF…") } } }
            }
            .disabled(working || store.isImporting)
            .percuscorePanel()
            .navigationTitle("Export PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(working)
                }
            }
            .interactiveDismissDisabled(working || shared != nil)
            .sheet(item: $shared, onDismiss: cleanup) { item in
                PDFShareSheet(url: item.url) { failure in
                    error = failure
                    shared = nil
                }
            }
            .alert("Could not export PDF", isPresented: Binding(get: { error != nil && shared == nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }.percuscoreSheet()
    }
    private func prepare(marked: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                let url = try await store.exportPDF(scoreID: score.id, includeMarkings: marked)
                temporary = url; shared = SharedPDF(url: url)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func cleanup() {
        if let temporary { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        temporary = nil
    }
}

private struct PDFShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: (String?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            completion(error?.localizedDescription)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
