import SwiftUI

struct SetlistDetail: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: LibraryStore
    let setlistID: UUID
    let open: ([ReadingItem], Int) -> Void
    @State private var adding = false
    @State private var rename = false
    @State private var name = ""
    @State private var deleting = false
    @State private var editing = false
    private var setlist: ScoreSetlist? { store.index.setlists.first { $0.id == setlistID } }
    private var queue: [ReadingItem] { setlist?.entries.compactMap { store.index.resolve($0) } ?? [] }

    var body: some View {
        Group {
            if let setlist {
                VStack(spacing: 0) {
                    let heading = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(spacing: 18))
                    heading {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("THE RUN OF SHOW").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.accent)
                            Text("\(queue.count) pieces · one continuous performance").font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Button { if !queue.isEmpty { open(queue, 0) } } label: { Label("Start playing", systemImage: "play.fill") }
                            .buttonStyle(GlassActionStyle(prominent: true)).disabled(queue.isEmpty)
                    }.padding(28)
                    if setlist.entries.isEmpty {
                        ContentUnavailableView("Build your program", systemImage: "list.bullet.rectangle", description: Text("Add scores or bookmarked excerpts, then drag them into performance order."))
                    } else {
                        List {
                            ForEach(Array(setlist.entries.enumerated()), id: \.element.id) { offset, entry in
                                if let item = store.index.resolve(entry) {
                                    Button {
                                        if let i = queue.firstIndex(where: { $0.id == entry.id }) { open(queue, i) }
                                    } label: {
                                        HStack(spacing: 20) {
                                            Text(String(format: "%02d", offset + 1)).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent).frame(width: 36)
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(item.title).font(.headline).foregroundStyle(Theme.ink)
                                                Text("\(item.endPage - item.startPage + 1) pages" + (entry.bookmarkID != nil ? " · excerpt" : ""))
                                                    .font(.caption).foregroundStyle(Theme.muted)
                                            }
                                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                        }.padding(.vertical, 12)
                                    }.disabled(editing)
                                } else if let score = store.index.scores.first(where: { $0.id == entry.scoreID }), score.isDeleted {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("\(offset + 1). \(score.title)").font(.headline)
                                        Text("Moved to Recently Deleted · skipped during performance")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 12)
                                }
                            }
                            .onMove { source, destination in
                                store.update { index in
                                    guard let i = index.setlists.firstIndex(where: { $0.id == setlistID }) else { return }
                                    index.setlists[i].entries.move(fromOffsets: source, toOffset: destination)
                                }
                            }
                            .onDelete { offsets in
                                store.update { index in
                                    guard let i = index.setlists.firstIndex(where: { $0.id == setlistID }) else { return }
                                    index.setlists[i].entries.remove(atOffsets: offsets)
                                }
                            }
                        }.listStyle(.insetGrouped).percuscorePanel()
                            .environment(\.editMode, .constant(editing ? .active : .inactive))
                    }
                    let footer = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(spacing: 12))
                    footer {
                        Button { adding = true } label: { Label("Add scores & excerpts", systemImage: "plus") }.buttonStyle(GlassActionStyle())
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text("References your library. No duplicate PDFs.").font(.caption).foregroundStyle(Theme.muted)
                    }.padding(28)
                }
                .background(Theme.groupedBackground)
                .onDrop(of: ["com.adobe.pdf"], isTargeted: nil) { store.receiveDrop($0, into: setlistID) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editing ? "Done" : "Reorder") { editing.toggle() }.disabled(setlist.entries.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Rename", systemImage: "pencil") { name = setlist.title; rename = true }
                            Button("Delete setlist", systemImage: "trash", role: .destructive) { deleting = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            } else { ContentUnavailableView("Select a setlist", systemImage: "list.bullet.rectangle") }
        }
        .sheet(isPresented: $adding) { AddToSetlistView(setlistID: setlistID).environmentObject(store) }
        .alert("Rename setlist", isPresented: $rename) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { store.update { if let i = $0.setlists.firstIndex(where: { $0.id == setlistID }) { $0.setlists[i].title = clean } } }
            }
        }
        .alert("Delete this setlist?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { store.update { $0.setlists.removeAll { $0.id == setlistID } } }
        } message: { Text("Your scores and annotations remain in the library.") }
    }
}

struct AddToSetlistView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let setlistID: UUID
    @State private var query = ""
    private var entries: [SetlistEntry] { store.index.setlists.first { $0.id == setlistID }?.entries ?? [] }
    var body: some View {
        NavigationStack {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        availableScores
                        currentProgram.frame(maxHeight: 210)
                    }
                } else {
                    HStack(spacing: 0) { availableScores; Divider(); currentProgram }
                }
            }
            .navigationTitle("Build your setlist")
            .searchable(text: $query, prompt: "Search scores and excerpts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.percuscoreSheet().presentationDetents([.large])
    }
    private var availableScores: some View {
        List {
            Section("Library · tap to add") {
                ForEach(store.index.activeScores.sorted { $0.title < $1.title }) { score in
                    if score.matchesSearch(query) {
                        addRow(title: score.title, detail: "\(score.pageCount) pages", entry: .init(scoreID: score.id))
                    }
                    ForEach(score.bookmarks.filter { $0.isItem && (score.matchesSearch(query, additionalText: $0.title)) }) { bookmark in
                        addRow(title: bookmark.title, detail: "Excerpt · \(score.title)", entry: .init(scoreID: score.id, bookmarkID: bookmark.id))
                    }
                }
            }
        }.listStyle(.insetGrouped).percuscorePanel()
    }
    private var currentProgram: some View {
        List {
            Section("Current program · \(entries.count)") {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    if let score = store.index.scores.first(where: { $0.id == entry.scoreID }), score.isDeleted {
                        Text("\(i + 1). \(score.title) · Recently Deleted").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("\(i + 1). \(store.index.resolve(entry)?.title ?? "Unavailable")").font(.subheadline)
                    }
                }
            }
        }.listStyle(.insetGrouped).percuscorePanel()
    }
    private func addRow(title: String, detail: String, entry: SetlistEntry) -> some View {
        Button {
            // Allocate identity per action so repeated additions cannot reuse the view's entry ID.
            let added = SetlistEntry(scoreID: entry.scoreID, bookmarkID: entry.bookmarkID)
            store.update { if let i = $0.setlists.firstIndex(where: { $0.id == setlistID }) { $0.setlists[i].entries.append(added) } }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(title); Text(detail).font(.caption).foregroundStyle(Theme.muted) }
                Spacer()
                Image(systemName: "plus").frame(width: 44, height: 44)
                    .foregroundStyle(Theme.accent).liquidGlass(in: Circle(), interactive: true)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("Adds this score or excerpt to the setlist")
    }
}
