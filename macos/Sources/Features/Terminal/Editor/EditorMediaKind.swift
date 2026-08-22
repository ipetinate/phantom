import Foundation

/// A file the editor *shows* rather than lets you edit.
///
/// Decided by extension, and deliberately not by sniffing bytes. The sniff in
/// `FileOpenGuard` answers a different question — "does this look like text" —
/// and it answers it inconsistently for exactly the family that motivates this
/// type: a PDF puts a NUL in its first 8KB only if a compressed stream happens
/// to land there, so two PDFs in the same repository were reaching opposite
/// verdicts. One opened as an editable wall of mojibake that ⌘S would have
/// written back as UTF-8, destroying the file.
///
/// Routing on the name also means the decision is available *before* any of
/// the file is read, so a media file never reaches the text decoder at all.
/// The cost is honest and small: a `.png` that is not a PNG says it cannot be
/// read instead of being refused as binary, which is both true and what the
/// Finder does.
enum EditorMediaKind: Equatable, Sendable, CaseIterable {
    case image
    case pdf

    static func resolve(fileName: String) -> EditorMediaKind? {
        let suffix = (fileName as NSString).pathExtension.lowercased()
        guard !suffix.isEmpty else { return nil }

        if imageSuffixes.contains(suffix) { return .image }
        if suffix == "pdf" { return .pdf }
        return nil
    }

    /// `svg` is **not** here, on purpose. It is XML that people hand-edit, and
    /// a media tab has no way back to the source — routing it here would take
    /// away the ability to edit a text file in exchange for a preview nobody
    /// asked for. `ico` is absent for a duller reason: nothing in this project
    /// has ever wanted to look at one.
    private static let imageSuffixes: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
    ]
}
