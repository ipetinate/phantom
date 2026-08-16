import Foundation

/// One line of a unified diff, with the line numbers it holds on each side.
///
/// The numbers are the point of this type. A side-by-side view draws them in
/// the gutter, and they are emphatically *not* the row index: a hunk that
/// starts at line 400 draws its first row at the top of the pane, and after
/// a block of additions the two sides no longer agree on where they are.
/// Both numbers are carried per line and both can be absent — an added line
/// never existed on the left, a removed one no longer exists on the right.
struct GitDiffLine: Equatable {
    enum Kind: Equatable {
        /// Unchanged; appears on both sides.
        case context

        /// Present only in the new version.
        case added

        /// Present only in the old version.
        case removed
    }

    let kind: Kind

    /// Exactly what git printed after the marker character.
    ///
    /// Kept byte-for-byte, carriage return included. A file converted from
    /// LF to CRLF differs on every line and *only* in that character, so
    /// stripping it here would turn a real diff into a screen where every
    /// pair looks identical and the viewer looks broken. Draw
    /// ``displayText`` instead, and use ``hasCarriageReturn`` when the two
    /// sides of a row disagree and the reader deserves to know why.
    let text: String

    /// 1-based line number in the old version; nil on an added line.
    let oldNumber: Int?

    /// 1-based line number in the new version; nil on a removed line.
    let newNumber: Int?

    /// Git followed this line with `\ No newline at end of file`.
    ///
    /// That marker is a property of the line above it, not a line of its
    /// own — parsing it as one puts a stray row in the middle of the diff.
    let isEndOfFileWithoutNewline: Bool

    /// ``text`` without the carriage return a CRLF file leaves on the end.
    var displayText: String {
        text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    var hasCarriageReturn: Bool { text.hasSuffix("\r") }
}

/// A run of changed lines and the context around it.
struct GitDiffHunk: Equatable {
    /// The `@@ -old +new @@` line, taken apart.
    ///
    /// A count is legal to omit and means 1: `@@ -1 +1 @@` is what git
    /// prints for a one-line file, and reading the missing field as 0
    /// silently drops the only line of the hunk.
    struct Header: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int

        /// What git prints after the closing `@@` — the enclosing function,
        /// when it can work one out. Empty when it printed nothing.
        let heading: String

        /// `@@ -1,3 +1,4 @@`, rebuilt from the parts with git's own rule
        /// that a count of 1 is written by leaving it out.
        var range: String {
            let old = oldCount == 1 ? "\(oldStart)" : "\(oldStart),\(oldCount)"
            let new = newCount == 1 ? "\(newStart)" : "\(newStart),\(newCount)"
            return "@@ -\(old) +\(new) @@"
        }

        /// The whole header line as git wrote it.
        var text: String {
            heading.isEmpty ? range : "\(range) \(heading)"
        }
    }

    let header: Header
    let lines: [GitDiffLine]
}

/// Everything one file's diff says, whether or not it has any lines.
///
/// A diff with no hunks is not an empty diff. It is a mode change, a rename
/// that moved a file without touching it, a new empty file, or a binary
/// file git refused to describe — four different things the viewer has to
/// say out loud, because a blank pane reads as a bug.
struct GitFileDiff: Equatable, Identifiable {
    enum Status: Equatable {
        case added
        case deleted
        case modified
        case renamed
        case copied
    }

    /// The path the file has after the change, or the path it had when it
    /// was deleted.
    let path: String

    /// Where a rename or a copy came from.
    let previousPath: String?

    let status: Status

    /// File modes, when git mentioned them. Present on their own for the
    /// `chmod +x` with no content change.
    let oldMode: String?
    let newMode: String?

    /// Git said `Binary files … differ`. There is no line content to show
    /// and no honest way to invent any.
    let isBinary: Bool

    /// A conflicted path. Git answers with a combined diff (`diff --cc`),
    /// which carries one column per merge parent and a marker character per
    /// parent on every line — a different format, not a wider version of
    /// this one. It is recognized so the viewer can say so; conflict
    /// resolution is its own feature.
    let isCombined: Bool

    let hunks: [GitDiffHunk]

    var id: String { path }

    var lines: [GitDiffLine] { hunks.flatMap(\.lines) }

    var addedCount: Int { lines.filter { $0.kind == .added }.count }

    var removedCount: Int { lines.filter { $0.kind == .removed }.count }

    /// Nothing to draw *and* nothing to say: no hunks, and none of the four
    /// other reasons a file can have none.
    ///
    /// Every one of those reasons is a sentence the viewer owes the reader,
    /// so each has to be subtracted here by name. Leaving one out makes a
    /// renamed file look like a diff that failed to load.
    var isEmpty: Bool {
        hunks.isEmpty && !isBinary && !isCombined && !isModeChangeOnly && !isPureRename
    }

    /// The `chmod` case: git reported both modes and nothing else.
    var isModeChangeOnly: Bool {
        guard hunks.isEmpty, !isBinary, !isCombined else { return false }
        guard let oldMode, let newMode else { return false }
        return oldMode != newMode
    }

    /// A rename or copy that carried the file across without editing it.
    var isPureRename: Bool {
        hunks.isEmpty && !isBinary && !isCombined && (status == .renamed || status == .copied)
    }
}
