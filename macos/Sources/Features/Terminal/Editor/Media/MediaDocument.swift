import Foundation

/// One open media file.
///
/// A struct with no methods, and that is the design rather than an omission.
/// There is no `save()` to reach for, no `isDirty` to track and no text buffer
/// to decode — so the corruption a `.pdf` opened as an `EditorDocument` could
/// cause is not guarded against here, it is unrepresentable.
///
/// `EditorCenter` keeps these in a map of their own for the same reason. One
/// map of an enum over both kinds would put a `case .media:` arm in front of
/// every existing lookup, and each of those arms is an invitation to write
/// something into a file that cannot take it.
struct MediaDocument: Identifiable, Equatable, Sendable {
    let url: URL
    let kind: EditorMediaKind

    var id: String { url.path }
}
