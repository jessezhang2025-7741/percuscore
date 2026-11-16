import SwiftUI

struct PageNavigatorPanel: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var index: PageNavigatorIndex?
    @State private var thumbnails: PageThumbnailProvider?
    @State private var input = ""
    @State private var showLocations = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NavigationRecoveryNotice(model: model, recovered: { dismiss() }).padding(.horizontal, 16)
                if let index {
                    pageInput(index).padding(16)
                    Picker("Navigation view", selection: $showLocations) {
                        Text("Pages").tag(false)
                        Text("Contents").tag(true)
                    }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12)
                    if showLocations { locations(index) }
                    else { pages(index) }
                } else if let error {
                    ContentUnavailableView("Unable to load pages", systemImage: "doc.badge.ellipsis", description: Text(error))
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Theme.groupedBackground)
            .navigationTitle("Go to page").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityLabel("Close page navigator")
                }
            }
            .task {
                do {
                    let document = try model.document(model.scoreID)
                    index = PageNavigatorIndex(document: document, item: model.session.item,
                        bookmarks: model.currentScore?.bookmarks ?? [])
                    if let url = store.fileURL(model.scoreID) { thumbnails = PageThumbnailProvider(url: url) }
                    input = String(model.pageIndex + 1)
                } catch { self.error = error.localizedDescription }
            }
        }.percuscoreSheet().presentationDetents([.large])
    }

    private func pageInput(_ index: PageNavigatorIndex) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("PDF page", text: $input).textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad).submitLabel(.go).focused($inputFocused)
                    .accessibilityLabel("PDF page number").onSubmit { jumpInput(index) }
                Button("Go") { jumpInput(index) }.frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(GlassActionStyle(prominent: true)).disabled(index.target(for: input) == nil)
                    .accessibilityLabel("Jump to page")
            }
            if let first = index.pages.first, let last = index.pages.last {
                Text("PDF pages \(first + 1)–\(last + 1) · Current page \(model.pageIndex + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.accent).accessibilityLabel("Page jump failed: \(error)") }
            else if !input.isEmpty && index.target(for: input) == nil {
                Text("Enter a page within the range above.").font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }

    private func pages(_ index: PageNavigatorIndex) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .top)] : [GridItem(.adaptive(minimum: 124), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(index.pages, id: \.self) { page in
                        PageNavigatorTile(page: page, current: page == model.pageIndex,
                            locations: index.locations(on: page), thumbnails: thumbnails) { jump(page) }
                            .id(page)
                    }
                }.padding(16)
            }.scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo(model.pageIndex, anchor: .center) }
        }
    }

    private func locations(_ index: PageNavigatorIndex) -> some View {
        List {
            if !index.bookmarks.isEmpty { Section("Bookmarks") { ForEach(index.bookmarks) { locationRow($0) } } }
            if !index.sections.isEmpty { Section("Movements & PDF sections") { ForEach(index.sections) { locationRow($0) } } }
            if index.locations.isEmpty {
                ContentUnavailableView("No locations yet", systemImage: "bookmark",
                    description: Text("PDF contents and your named page or range bookmarks appear here. Add bookmarks from the reader’s Bookmarks menu."))
            }
        }.scrollDismissesKeyboard(.interactively).percuscorePanel()
    }

    private func locationRow(_ location: PageLocation) -> some View {
        Button { jump(location.page) } label: {
            HStack(spacing: 12) {
                Image(systemName: location.isOutline ? "list.bullet.rectangle" : "bookmark.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(location.title).font(.headline).foregroundStyle(.primary)
                    Text(location.endPage.map { "Pages \(location.page + 1)–\($0 + 1)" } ?? "Page \(location.page + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if location.page == model.pageIndex { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }.padding(.leading, CGFloat(min(2, location.depth)) * 12).padding(.vertical, 4)
        }.accessibilityLabel("\(location.title), Page \(location.page + 1)")
    }

    private func jumpInput(_ index: PageNavigatorIndex) {
        guard let page = index.target(for: input) else { return }
        jump(page)
    }
    private func jump(_ page: Int) {
        inputFocused = false
        if model.seek(page) { dismiss() }
        else {
            error = model.navigationFailure == nil
                ? (model.errorMessage ?? "This page is temporarily unavailable. Keep the current page open and try again.") : nil
            if model.navigationFailure == nil { model.errorMessage = nil }
        }
    }
}

private struct PageNavigatorTile: View {
    let page: Int
    let current: Bool
    let locations: [PageLocation]
    let thumbnails: PageThumbnailProvider?
    let action: () -> Void
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Color.white
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                    else if loaded { Image(systemName: "doc").foregroundStyle(.gray) }
                    else { ProgressView() }
                }.frame(height: 176).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? Theme.accent : Color.primary.opacity(0.10), lineWidth: current ? 3 : 1))
                HStack(spacing: 5) {
                    Text("Page \(page + 1)").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if current { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    if locations.contains(where: { !$0.isOutline }) { Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent) }
                    if locations.contains(where: \.isOutline) { Image(systemName: "list.bullet.rectangle").foregroundStyle(Theme.accent) }
                }
                if !locations.isEmpty {
                    Text(locations.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(Theme.accent).lineLimit(2)
                }
            }.foregroundStyle(.primary).padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
            .accessibilityLabel("Go to page \(page + 1)")
            .accessibilityValue(([current ? "Current page" : ""] + locations.map(\.title)).filter { !$0.isEmpty }.joined(separator: ", "))
            .task(id: page) {
                let rendered = await thumbnails?.image(for: page)
                guard !Task.isCancelled else { return }
                image = rendered
                loaded = true
            }
            .onDisappear { image = nil; loaded = false }
    }
}
