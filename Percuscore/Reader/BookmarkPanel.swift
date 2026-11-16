import SwiftUI

struct BookmarkPanel: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ScoreBookmark?
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.currentScore?.bookmarks.sorted { $0.startPage < $1.startPage } ?? []) { bookmark in
                        HStack {
                            Button {
                                if model.seek(bookmark.startPage) { dismiss() }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: bookmark.isItem ? "bookmark.fill" : "bookmark")
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(bookmark.title).font(.headline)
                                        Text(bookmark.isItem ? "Pages \(bookmark.startPage + 1)–\(bookmark.endPage! + 1) · Library item" : "Page \(bookmark.startPage + 1)")
                                            .font(.caption).foregroundStyle(Theme.muted)
                                    }
                                }
                            }.accessibilityLabel("Go to \(bookmark.title), page \(bookmark.startPage + 1)")
                                .disabled(bookmark.startPage < model.session.item.startPage || bookmark.startPage > model.session.item.endPage)
                            Spacer()
                            Button { editing = bookmark } label: { Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle()) }
                                .buttonStyle(GlassActionStyle()).accessibilityLabel("Edit bookmark \(bookmark.title)")
                        }.padding(.vertical, 5)
                            .swipeActions { Button("Delete", role: .destructive) { store.update { $0.removeBookmark(scoreID: model.scoreID, bookmarkID: bookmark.id) } } }
                    }
                } header: { Text("Inside this PDF") } footer: {
                    Text("Page bookmarks jump to a location. Item bookmarks also appear as excerpts in your library. When reading an excerpt, jumps stay within its page range.")
                }
                Button { adding = true } label: { Label("Add bookmark at page \(model.pageIndex + 1)", systemImage: "plus") }
                    .buttonStyle(GlassActionStyle()).padding(.vertical, 4)
            }
            .percuscorePanel()
            .navigationTitle("Bookmarks")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.percuscoreSheet()
        .sheet(isPresented: $adding) { BookmarkEditor(store: store, scoreID: model.scoreID, initial: .init(title: "", startPage: model.pageIndex)) }
        .sheet(item: $editing) { bookmark in BookmarkEditor(store: store, scoreID: model.scoreID, initial: bookmark) }
    }
}

struct BookmarkEditor: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let scoreID: UUID
    let initial: ScoreBookmark
    @State private var title: String
    @State private var start: Int
    @State private var end: Int
    @State private var isItem: Bool
    init(store: LibraryStore, scoreID: UUID, initial: ScoreBookmark) {
        self.store = store; self.scoreID = scoreID; self.initial = initial
        _title = State(initialValue: initial.title); _start = State(initialValue: initial.startPage + 1)
        _end = State(initialValue: (initial.endPage ?? initial.startPage) + 1); _isItem = State(initialValue: initial.isItem)
    }
    private var pageCount: Int { max(1, store.score(scoreID)?.pageCount ?? 1) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("e.g. Movement III", text: $title)
                Picker("Type", selection: $isItem) { Text("Page bookmark").tag(false); Text("Item bookmark").tag(true) }.pickerStyle(.segmented)
                Stepper("\(isItem ? "Start page" : "Page"): \(start)", value: $start, in: 1...pageCount)
                if isItem { Stepper("End page: \(end)", value: $end, in: start...max(start, pageCount)) }
                Text(isItem ? "This page range can be added to setlists without splitting or copying the PDF." : "A named jump point inside this PDF.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .onChange(of: start) { _, value in if end < value { end = value } }
            .percuscorePanel()
            .navigationTitle(initial.title.isEmpty ? "New bookmark" : "Edit bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let bookmark = ScoreBookmark(id: initial.id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), startPage: start - 1, endPage: isItem ? end - 1 : nil)
                        if store.saveBookmark(bookmark, scoreID: scoreID) { dismiss() }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.percuscoreSheet()
    }
}
