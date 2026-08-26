import Foundation

/// Turns "what this file used to be" into the `+` and `-` the gutter draws.
///
/// Line arrays rather than a parsed `git diff`, and that is the point: the
/// reader is looking at a buffer, not at the file on disk, so a diff produced
/// by running git would be stale from the first keystroke until the next save.
/// Comparing the buffer against the committed text keeps the margin honest
/// while the reader types, which is the behaviour the gutter is expected to
/// have.
///
/// `CollectionDifference` does the matching. It is the standard library's, it
/// is the same longest-common-subsequence answer `git diff` gives, and not
/// writing a second one means there is no second one to be wrong.
enum EditorDiffMarks {
    /// Files past this many lines are not compared.
    ///
    /// `difference(from:)` costs O(n·d) — fine for an edit, punishing for two
    /// large and dissimilar files, and this runs while somebody is typing. A
    /// file over the bound gets no marks rather than a stuttering editor, and
    /// the number is generous: a 20,000-line file is far past where anything
    /// in this repository lives.
    static let lineBudget = 20_000

    /// Marks keyed by one-based line number in `current`, which is what the
    /// reader is looking at and how the numbers beside them are counted.
    ///
    /// The rule is the reader's own: `+` is new, `-` is what is leaving or
    /// being altered.
    ///
    /// A line that is only in `current`, replacing nothing, is `+`. A run only
    /// in `base` is `-`, reported against the line that now sits where it was,
    /// because a deleted line has no line of its own to be marked on and that
    /// is where a reader looks to find what used to be there.
    ///
    /// A *changed* line — a removal and an insertion in the same place — is
    /// `-`, because something left it. That is a deliberate reading and not
    /// the only possible one: the text sitting there now is the new text, so
    /// `+` would also be defensible. It is `-` because the question the margin
    /// answers is "what did I disturb here", and a line whose old content is
    /// gone was disturbed.
    static func marks(
        current: [String],
        base: [String]
    ) -> [Int: CodeGutterView.DiffMark] {
        guard current.count <= lineBudget, base.count <= lineBudget else { return [:] }
        guard current != base else { return [:] }

        let difference = current.difference(from: base)
        let inserted = Set(difference.insertions.map(offset))
        let removed = Set(difference.removals.map(offset))

        var marks: [Int: CodeGutterView.DiffMark] = [:]
        var baseIndex = 0
        var currentIndex = 0
        var deletionPending = false

        while baseIndex < base.count || currentIndex < current.count {
            let isRemoved = baseIndex < base.count && removed.contains(baseIndex)
            let isInserted = currentIndex < current.count && inserted.contains(currentIndex)

            switch (isRemoved, isInserted) {
            case (true, true):
                /// A change: something left this line. Clearing the flag is
                /// what stops the line *after* a change from also being
                /// blamed for the removal.
                marks[currentIndex + 1] = .removed
                deletionPending = false
                baseIndex += 1
                currentIndex += 1

            case (false, true):
                marks[currentIndex + 1] = .added
                deletionPending = false
                currentIndex += 1

            case (true, false):
                deletionPending = true
                baseIndex += 1

            case (false, false):
                if deletionPending, currentIndex < current.count,
                   marks[currentIndex + 1] == nil {
                    marks[currentIndex + 1] = .removed
                }
                deletionPending = false
                baseIndex += 1
                currentIndex += 1
            }
        }

        /// A deletion with nothing after it took the end of the file with it.
        /// It is reported against the last line still there to carry it.
        if deletionPending, !current.isEmpty, marks[current.count] == nil {
            marks[current.count] = .removed
        }

        return marks
    }

    /// Splitting a file the way the editor counts lines.
    ///
    /// A trailing newline is dropped rather than becoming an empty last line,
    /// because the editor does not show one either — keeping it would put a
    /// phantom `+` on the line after the end of every file that gained a
    /// newline.
    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func offset(
        _ change: CollectionDifference<String>.Change
    ) -> Int {
        switch change {
        case .insert(let offset, _, _): return offset
        case .remove(let offset, _, _): return offset
        }
    }
}
