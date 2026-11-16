import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReadingLaunch: Identifiable {
    let id = UUID()
    let session: ReadingSession
}

struct LibraryExcerpt: Identifiable {
    let score: Score
    let bookmark: ScoreBookmark
    // Bookmark UUIDs are unique within a score, including after additive restore.
    struct ID: Hashable {
        let scoreID: UUID
        let bookmarkID: UUID
    }
    var id: ID { ID(scoreID: score.id, bookmarkID: bookmark.id) }

    static func items(in scores: [Score]) -> [LibraryExcerpt] {
        scores.flatMap { score in
            score.bookmarks.filter(\.isItem).map { LibraryExcerpt(score: score, bookmark: $0) }
        }
    }
}

private enum LibrarySection: Hashable {
    case all, recent, favorites, deleted, setlist(UUID)
}

private enum LibraryLayout: String {
    case grid, list
}

private extension LibrarySort {
    var label: String {
        switch self {
        case .title: return "Title"
        case .composer: return "Composer"
        case .lastOpened: return "Last opened"
        case .imported: return "Date added"
        }
    }
    var usesDates: Bool { self == .lastOpened || self == .imported }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var section: LibrarySection? = .all
    @State private var search = ""
    @State private var importing = false
    @State private var creatingSetlist = false
    @State private var setlistName = ""
    @State private var launch: ReadingLaunch?
    @State private var settings = false
    @State private var editingScore: Score?
    @State private var exportingScore: Score?
    @State private var removeScore: Score?
    @State private var isDropTargeted = false
    @AppStorage("library.layout") private var layoutRaw = LibraryLayout.grid.rawValue
    @AppStorage("library.sort") private var sortRaw = LibrarySort.title.rawValue
    @AppStorage("library.ascending") private var ascending = true
    @AppStorage("library.recentSort") private var recentSortRaw = LibrarySort.lastOpened.rawValue
    @AppStorage("library.recentAscending") private var recentAscending = false

    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: LibrarySort {
        section == .recent
            ? LibrarySort(rawValue: recentSortRaw) ?? .lastOpened
            : LibrarySort(rawValue: sortRaw) ?? .title
    }
    private var sortAscending: Bool { section == .recent ? recentAscending : ascending }
    private var sortBinding: Binding<LibrarySort> {
        Binding(get: { sort }, set: { value in
            if section == .recent {
                recentSortRaw = value.rawValue; recentAscending = !value.usesDates
            } else {
                sortRaw = value.rawValue; ascending = !value.usesDates
            }
        })
    }
    private var directionBinding: Binding<Bool> {
        Binding(get: { sortAscending }, set: { value in
            if section == .recent { recentAscending = value } else { ascending = value }
        })
    }
    private var layoutBinding: Binding<LibraryLayout> {
        Binding(get: { layout }, set: { layoutRaw = $0.rawValue })
    }

    private var scores: [Score] {
        var result = store.index.activeScores.filter { $0.matchesSearch(search) }
        if section == .favorites { result = result.filter(\.isFavorite) }
        if section == .recent { result = result.filter { $0.lastOpenedAt != nil } }
        return sort.arranged(result, ascending: sortAscending)
    }
    private var title: String {
        switch section {
        case .recent: return "Recently played"
        case .favorites: return "Favorites"
        case .deleted: return "Recently Deleted"
        case .setlist(let id): return store.index.setlists.first { $0.id == id }?.title ?? "Setlist"
        default: return store.isAcceptanceLibrary ? "Test library" : "Your library"
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list").font(.title2).foregroundStyle(Theme.accent)
                    Text("Percuscore").font(.title3.weight(.bold))
                }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
                Text(store.isolationLabel ?? (store.isAcceptanceLibrary ? "DEVICE ACCEPTANCE · ISOLATED TEST SCORES" : "A little space for your music."))
                    .font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 22).padding(.bottom, 14)
                List(selection: $section) {
                    Section("LIBRARY") {
                        Label("All scores", systemImage: "square.grid.2x2").tag(LibrarySection.all)
                        Label("Recently played", systemImage: "clock").tag(LibrarySection.recent)
                        Label("Favorites", systemImage: "star").tag(LibrarySection.favorites)
                        Label("Recently Deleted", systemImage: "trash").tag(LibrarySection.deleted)
                    }
                    Section {
                        ForEach(store.index.setlists) { setlist in
                            Label(setlist.title, systemImage: "list.bullet.rectangle")
                                .tag(LibrarySection.setlist(setlist.id))
                                .onDrop(of: [UTType.pdf.identifier], isTargeted: nil) { providers in
                                    store.receiveDrop(providers, into: setlist.id)
                                }
                        }
                        Button { creatingSetlist = true } label: { Label("New setlist", systemImage: "plus") }
                    } header: { Text("SETLISTS") }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                GlassControlGroup(spacing: 8) {
                    VStack(spacing: 12) {
                        Button { importing = true } label: {
                            Label("Import PDF", systemImage: "plus")
                                .fontWeight(.semibold).frame(maxWidth: .infinity).frame(minHeight: 44)
                        }.buttonStyle(GlassActionStyle(prominent: true))
                            .disabled(!store.isReady || store.isImporting)
                        Button { settings = true } label: {
                            Label("Reader settings", systemImage: "slider.horizontal.3")
                                .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 44)
                        }.buttonStyle(GlassActionStyle())
                    }
                }.padding(20)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
        } detail: {
            Group {
                if case .setlist(let id) = section {
                    SetlistDetail(setlistID: id, open: { queue, i in
                        if let session = ReadingSession(queue: queue, startIndex: i) { launch = ReadingLaunch(session: session) }
                    })
                } else if section == .deleted {
                    RecentlyDeletedView().environmentObject(store)
                } else {
                    libraryContent
                }
            }
            .navigationTitle(title)
            .toolbar {
                if store.isAcceptanceLibrary {
                    ToolbarItem(placement: .topBarLeading) { Button("Exit test library") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import PDF", systemImage: "square.and.arrow.down") }
                        .disabled(!store.isReady || store.isImporting)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if store.isImporting {
                HStack { ProgressView(); Text(store.importProgress).font(.subheadline) }
                    .padding().liquidGlass(in: Capsule()).padding(24)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let target: UUID? = { if case .setlist(let id) = section { return id }; return nil }()
                Task { _ = await store.importPDFs(urls, into: target) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(item: $launch) { launch in ReaderView(store: store, session: launch.session) }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(store) }
        .alert("New setlist", isPresented: $creatingSetlist) {
            TextField("e.g. Fall concert", text: $setlistName)
            Button("Cancel", role: .cancel) { setlistName = "" }
            Button("Create") {
                let name = setlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let list = ScoreSetlist(title: name)
                if store.update({ $0.setlists.append(list) }) { section = .setlist(list.id) }
                setlistName = ""
            }.disabled(setlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(item: $exportingScore) { score in PDFExportView(score: score).environmentObject(store) }
        .sheet(item: $editingScore) { score in
            ScoreDetailsEditor(score: score).environmentObject(store)
        }
        .alert("Move to Recently Deleted?", isPresented: Binding(get: { removeScore != nil }, set: { if !$0 { removeScore = nil } })) {
            Button("Cancel", role: .cancel) { removeScore = nil }
            Button("Move", role: .destructive) {
                if let id = removeScore?.id { store.moveToRecentlyDeleted(id) }
                removeScore = nil
            }
        } message: { Text("Your PDF, markings, drafts and page settings stay together. Setlists skip this score until you restore it. Nothing is automatically erased.") }
        .alert("Percuscore", isPresented: Binding(get: { store.errorMessage != nil && launch == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    browseControls(compact: false)
                    browseControls(compact: true)
                    browseControls(compact: true, stacked: true)
                }
                if !store.isReady {
                    ContentUnavailableView {
                        Label("Library needs attention", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text("Your files have been preserved. Check available storage and try again.") }
                    actions: { Button("Try again") { store.reload() }.buttonStyle(GlassActionStyle()) }
                } else if scores.isEmpty {
                    ContentUnavailableView {
                        Label(store.index.activeScores.isEmpty ? "Your next rehearsal starts here" : "No matching scores", systemImage: "music.note")
                    } description: {
                        Text("Import a PDF from Files. Your library keeps its own local copy.")
                    } actions: {
                        Button("Import your first PDF") { importing = true }.buttonStyle(GlassActionStyle(prominent: true))
                        if store.index.activeScores.isEmpty {
                            Button("Try an original practice score") { Task { await store.addSample() } }
                                .buttonStyle(GlassActionStyle()).disabled(store.isImporting)
                        }
                    }.padding(.top, 24)
                } else {
                    if layout == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 168,
                                                        maximum: dynamicTypeSize.isAccessibilitySize ? 450 : 240), spacing: 16)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(scores) { score in scoreGridItem(score) }
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(scores) { score in
                                HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                                    Button { open(score) } label: { ScoreListRow(score: score) }
                                        .buttonStyle(.plain)
                                        .contextMenu { scoreActions(score) }
                                    Menu { scoreActions(score) } label: {
                                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                            .liquidGlass(in: Circle(), interactive: true)
                                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                                        .accessibilityLabel("Actions for \(score.title)")
                                }.padding(.vertical, 8)
                                Divider().padding(.leading, 78)
                            }
                        }
                    }
                    let excerpts = LibraryExcerpt.items(in: scores)
                    if !excerpts.isEmpty {
                        Text("EXCERPTS & MOVEMENTS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.muted)
                        ForEach(excerpts) { excerpt in
                            let score = excerpt.score, bookmark = excerpt.bookmark
                            Button { open(score, bookmark: bookmark) } label: {
                                HStack {
                                    Image(systemName: "bookmark").frame(width: 32)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(bookmark.title).font(.headline)
                                        Text("\(score.title) · pp. \(bookmark.startPage + 1)–\((bookmark.endPage ?? bookmark.startPage) + 1)")
                                            .font(.caption).foregroundStyle(Theme.muted)
                                    }
                                    Spacer(); Image(systemName: "chevron.right")
                                }.padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Title, composer, part or tags")
        .overlay { if isDropTargeted { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(12).allowsHitTesting(false) } }
        .onDrop(of: [UTType.pdf.identifier], isTargeted: $isDropTargeted) { store.receiveDrop($0) }
    }

    private func browseControls(compact: Bool, stacked: Bool = false) -> some View {
        let arrangement = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return arrangement {
            Text("\(scores.count) scores").font(.subheadline).foregroundStyle(Theme.muted).fixedSize()
            if !stacked { Spacer(minLength: 8) }
            GlassControlGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Sort by", selection: sortBinding) {
                            ForEach(LibrarySort.allCases, id: \.self) { choice in Text(choice.label).tag(choice) }
                        }
                        Picker("Order", selection: directionBinding) {
                            Text(sort.usesDates ? "Oldest first" : "A to Z").tag(true)
                            Text(sort.usesDates ? "Newest first" : "Z to A").tag(false)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.arrow.down")
                            if !compact { Text(sort.label) }
                        }.font(.subheadline.weight(.medium)).fixedSize()
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .liquidGlass(in: Capsule(), interactive: true)
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .accessibilityLabel("Sort scores")
                        .accessibilityValue("\(sort.label), \(sortAscending ? "ascending" : "descending")")
                    Picker("Library layout", selection: layoutBinding) {
                        Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid).accessibilityLabel("Grid")
                        Image(systemName: "list.bullet").tag(LibraryLayout.list).accessibilityLabel("List")
                    }.pickerStyle(.segmented).frame(width: 96).frame(minHeight: 44)
                }
            }.disabled(!store.isReady)
        }
    }

    private func scoreGridItem(_ score: Score) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open(score) } label: { ScoreCard(score: score) }
                .buttonStyle(.plain).contextMenu { scoreActions(score) }
            GlassControlGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Button { editingScore = score } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 18)).frame(width: 44, height: 44)
                        }.accessibilityLabel("Edit details")
                    } else {
                        Button("Edit details", systemImage: "slider.horizontal.3") { editingScore = score }
                    }
                    Spacer(minLength: 0)
                    Button { exportingScore = score } label: {
                        if dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 18)).frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                        .accessibilityLabel("Export PDF")
                }.buttonStyle(GlassActionStyle()).controlSize(.small)
                    .font(.caption.weight(.medium)).frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private func scoreActions(_ score: Score) -> some View {
        Button(score.isFavorite ? "Remove favorite" : "Favorite", systemImage: "star") {
            store.update { if let i = $0.scores.firstIndex(where: { $0.id == score.id }) { $0.scores[i].isFavorite.toggle() } }
        }
        Button("Edit details", systemImage: "pencil") { editingScore = score }
        Button("Export PDF", systemImage: "square.and.arrow.up") { exportingScore = score }
        Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { removeScore = score }
    }

    private func open(_ score: Score, bookmark: ScoreBookmark? = nil) {
        let entry = SetlistEntry(scoreID: score.id, bookmarkID: bookmark?.id)
        guard let item = store.index.resolve(entry), let session = ReadingSession(queue: [item], page: bookmark == nil ? score.lastPage : nil) else { return }
        launch = ReadingLaunch(session: session)
    }
}

struct ScoreCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let score: Score
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScoreThumbnail(score: score).frame(height: 180)
            Text(score.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !score.composer.isEmpty { Text(score.composer).font(.caption).foregroundStyle(Theme.muted).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
            if !score.part.isEmpty { Text(score.part).font(.caption.weight(.medium)).foregroundStyle(Theme.accent).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
            if !score.tags.isEmpty { Text(score.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(Theme.muted).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(score.pageCount) pages")
                        if score.lastOpenedAt != nil { Text("Page \(score.lastPageNumber)") }
                    }
                } else {
                    HStack {
                        Text("\(score.pageCount) pages")
                        Spacer()
                        if score.lastOpenedAt != nil { Text("Page \(score.lastPageNumber)") }
                    }
                }
            }.font(.caption2).foregroundStyle(Theme.muted)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
            .accessibilityValue(score.isFavorite ? "Favorite" : "")
    }
}

private struct ScoreListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let score: Score
    var body: some View {
        let arrangement = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 14))
        let metadata = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        arrangement {
            ScoreThumbnail(score: score, compact: true).frame(width: 64, height: 84)
            VStack(alignment: .leading, spacing: 5) {
                Text(score.title).font(.headline).foregroundStyle(Theme.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading)
                let details = [score.composer, score.part].filter { !$0.isEmpty }.joined(separator: " · ")
                if !details.isEmpty { Text(details).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
                metadata {
                    Text("\(score.pageCount) pages")
                    if score.lastOpenedAt != nil { Text("Page \(score.lastPageNumber)") }
                    if !score.tags.isEmpty { Text(score.tags.joined(separator: " · ")).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
                }.font(.caption).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
            .accessibilityValue(score.isFavorite ? "Favorite" : "")
    }
}

private struct ScoreThumbnail: View {
    @EnvironmentObject private var store: LibraryStore
    let score: Score
    var compact = false
    @State private var thumbnail: UIImage?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous).fill(Theme.groupedBackground)
            Group {
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: "doc.richtext").font(compact ? .title3 : .largeTitle).foregroundStyle(Theme.muted) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(compact ? 7 : 12).shadow(color: .black.opacity(0.10), radius: compact ? 2 : 4, y: 2)
            if score.isFavorite {
                Image(systemName: "star.fill").font(.system(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(Theme.accent).frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                    .liquidGlass(in: Circle()).padding(compact ? 3 : 7)
            }
        }.accessibilityHidden(true).task(id: score.id) { thumbnail = await store.thumbnail(for: score) }
    }
}


private struct ScoreDetailsEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let score: Score
    @State private var title: String
    @State private var composer: String
    @State private var part: String
    @State private var tags: String
    @State private var saveError: String?

    init(score: Score) {
        self.score = score
        _title = State(initialValue: score.title)
        _composer = State(initialValue: score.composer)
        _part = State(initialValue: score.part)
        _tags = State(initialValue: score.tags.joined(separator: ", "))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Score") {
                    TextField("Work title", text: $title)
                    TextField("Composer, e.g. Gustav Mahler", text: $composer)
                    TextField("Instrument / Part, e.g. Timpani", text: $part)
                }
                Section {
                    TextField("Audition, Orchestra, Practice", text: $tags, axis: .vertical)
                } header: { Text("Tags") } footer: {
                    Text("Separate tags with commas. Search across all details with multiple words, e.g. Mahler + Timpani.")
                }
            }
            .percuscorePanel()
            .navigationTitle("Edit score details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }.percuscoreSheet()
    }
    private func save() {
        guard store.score(score.id) != nil else { saveError = "This score is no longer in your library."; return }
        var seen = Set<String>()
        let cleanTags = tags.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        if store.update({ library in
            guard let i = library.scores.firstIndex(where: { $0.id == score.id }) else { return }
            library.scores[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            library.scores[i].composer = composer.trimmingCharacters(in: .whitespacesAndNewlines)
            library.scores[i].part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            library.scores[i].tags = cleanTags
        }) { dismiss() }
        else { saveError = store.errorMessage; store.errorMessage = nil }
    }
}
