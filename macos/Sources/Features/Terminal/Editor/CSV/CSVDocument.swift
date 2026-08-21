import Foundation

/// A parsed CSV together with the sizing decision taken from it.
///
/// One value rather than two, because the two are always wanted together and
/// the layout is only meaningful for the table it was measured from.
struct CSVDocument: Equatable, Sendable {
    let table: CSVTable
    let layout: CSVColumnLayout

    static let empty = CSVDocument(table: .empty, layout: .empty)

    init(table: CSVTable, layout: CSVColumnLayout) {
        self.table = table
        self.layout = layout
    }

    init(text: String) {
        let table = CSVTable.parse(text)
        self.init(table: table, layout: .measure(table))
    }
}

/// The parse, kept between view updates.
///
/// A SwiftUI `body` runs whenever anything the pane is nested in changes —
/// a hover, a focus, a resize, the theme — and parsing a ten-megabyte export
/// on each of those would make the window stutter for reasons that have
/// nothing to do with the file. Same bargain as `MarkdownPreviewView`'s
/// fingerprint: hold the last answer, and recompute only when the text it
/// was computed from is a different string.
///
/// Comparing the whole text is what makes that check honest, and it is
/// cheaper than it looks: SwiftUI hands back the same `String` instance on an
/// unchanged update, so `==` settles on a pointer.
///
/// Deliberately not `ObservableObject`. Nothing here should invalidate a
/// view — the cache is a memo of what the view was already about to compute,
/// and publishing from inside `body` is how a render loop starts.
final class CSVDocumentCache {
    private var key: String?
    private var cached = CSVDocument.empty

    func document(for text: String) -> CSVDocument {
        if let key, key == text { return cached }
        key = text
        cached = CSVDocument(text: text)
        return cached
    }
}
