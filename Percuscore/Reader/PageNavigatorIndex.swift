import PDFKit

struct PageLocation: Identifiable {
    let id: String
    let title: String
    let page: Int
    let endPage: Int?
    let depth: Int
    let isOutline: Bool
}

struct PageNavigatorIndex {
    let pages: [Int]
    let locations: [PageLocation]
    var bookmarks: [PageLocation] { locations.filter { !$0.isOutline } }
    var sections: [PageLocation] { locations.filter(\.isOutline) }

    init(document: PDFDocument, item: ReadingItem, bookmarks: [ScoreBookmark]) {
        let lower = max(0, item.startPage), upper = min(item.endPage, document.pageCount - 1)
        guard lower <= upper else { pages = []; locations = []; return }
        let range = lower...upper
        pages = Array(range)
        var entries = bookmarks.filter { $0.isValid(pageCount: document.pageCount) && range.contains($0.startPage) }.map {
            PageLocation(id: "bookmark-\($0.id)", title: $0.title, page: $0.startPage,
                endPage: $0.endPage.map { min(upper, $0) }, depth: 0, isOutline: false)
        }
        if let root = document.outlineRoot {
            var pending: [(PDFOutline, String, Int)] = [(root, "root", -1)]
            while let (node, path, depth) = pending.popLast() {
                let destination = (node.action as? PDFActionGoTo)?.destination ?? node.destination
                if let title = node.label?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                   let page = destination?.page {
                    let number = document.index(for: page)
                    if range.contains(number) {
                        entries.append(.init(id: "outline-\(path)", title: title, page: number,
                            endPage: nil, depth: max(0, depth), isOutline: true))
                    }
                }
                for childIndex in (0..<node.numberOfChildren).reversed() {
                    if let child = node.child(at: childIndex) { pending.append((child, "\(path).\(childIndex)", depth + 1)) }
                }
            }
        }
        locations = entries.enumerated().sorted {
            $0.element.page == $1.element.page ? $0.offset < $1.offset : $0.element.page < $1.element.page
        }.map(\.element)
    }
    func target(for input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(text), number > 0, let first = pages.first, let last = pages.last,
              (first...last).contains(number - 1) else { return nil }
        return number - 1
    }
    func locations(on page: Int) -> [PageLocation] { locations.filter { $0.page == page } }
}
