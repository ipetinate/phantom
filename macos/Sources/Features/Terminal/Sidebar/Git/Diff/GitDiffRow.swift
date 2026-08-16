import Foundation

/// One row of a side-by-side diff: what to draw on the left, what to draw
/// on the right.
///
/// A unified diff is one column and a side-by-side view is two, and the
/// conversion is the place these views go wrong. A block of 3 removed lines
/// followed by 5 added ones is 5 rows, not 8 and not 3 — the two sides pair
/// off, and the two rows the left has nothing for are *blank filler*, drawn
/// as an empty band so the columns stay level. Modelling a side as
/// `GitDiffLine?` rather than as a line makes that filler something the
/// view has to handle rather than something it can forget.
struct GitDiffRow: Identifiable, Equatable {
    enum Content: Equatable {
        /// The band that marks lines the diff skipped over. Spans both
        /// columns; neither side has a line here.
        case gap(GitDiffHunk.Header)

        /// One line per side. `nil` is filler: the other side has a line
        /// this one doesn't.
        case lines(left: GitDiffLine?, right: GitDiffLine?, inline: GitDiffInlineEdits?)
    }

    /// Position in the row list. Stable for a given diff, which is all a
    /// `ForEach` needs, and not a line number on either side.
    let id: Int

    let content: Content

    /// The old version's line, or nil when this side is filler or a gap.
    var left: GitDiffLine? {
        guard case .lines(let left, _, _) = content else { return nil }
        return left
    }

    /// The new version's line, or nil when this side is filler or a gap.
    var right: GitDiffLine? {
        guard case .lines(_, let right, _) = content else { return nil }
        return right
    }

    /// Which characters differ, when both sides are present and the change
    /// is an edit rather than a replacement.
    var inline: GitDiffInlineEdits? {
        guard case .lines(_, _, let inline) = content else { return nil }
        return inline
    }

    var gap: GitDiffHunk.Header? {
        guard case .gap(let header) = content else { return nil }
        return header
    }
}

/// Lays a file's hunks out as side-by-side rows.
enum GitDiffAlignment {
    /// How many changed pairs get a word-level pass before it is dropped.
    ///
    /// The pass is cheap per row and this runs off the main thread, but a
    /// twelve-thousand-line refactor is a diff nobody reads character by
    /// character anyway, and the budget keeps the wait bounded. Rows past
    /// it still align; they just carry no ``GitDiffInlineEdits``.
    static let inlineEditBudget = 2_000

    nonisolated static func rows(for diff: GitFileDiff) -> [GitDiffRow] {
        var rows: [GitDiffRow] = []
        var budget = inlineEditBudget

        for (index, hunk) in diff.hunks.enumerated() {
            /// A gap band says "lines were skipped here". Above the first
            /// hunk of a file that starts at its own first line — every new
            /// file, and any edit near the top — nothing was skipped, and
            /// the band is a header for a gap that isn't there.
            if !(index == 0 && hunk.header.oldStart <= 1 && hunk.header.newStart <= 1) {
                rows.append(GitDiffRow(id: rows.count, content: .gap(hunk.header)))
            }

            var removed: [GitDiffLine] = []
            var added: [GitDiffLine] = []

            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    removed.append(line)
                case .added:
                    added.append(line)
                case .context:
                    flush(&removed, &added, into: &rows, budget: &budget)
                    rows.append(
                        GitDiffRow(id: rows.count, content: .lines(left: line, right: line, inline: nil))
                    )
                }
            }

            flush(&removed, &added, into: &rows, budget: &budget)
        }

        return rows
    }

    /// Pairs a block of removals with the block of additions that replaced
    /// it, in order, and lets the longer side spill into filler rows.
    ///
    /// Accumulating both sides and emitting on the next context line —
    /// rather than emitting each line as it arrives — is what makes a
    /// removal and the addition that replaced it land on the *same* row.
    /// Emitting eagerly puts them on consecutive rows and the two columns
    /// never line up again.
    private static func flush(
        _ removed: inout [GitDiffLine],
        _ added: inout [GitDiffLine],
        into rows: inout [GitDiffRow],
        budget: inout Int
    ) {
        defer {
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for offset in 0..<max(removed.count, added.count) {
            let left = offset < removed.count ? removed[offset] : nil
            let right = offset < added.count ? added[offset] : nil

            var inline: GitDiffInlineEdits?
            if let left, let right, budget > 0 {
                budget -= 1
                inline = GitDiffInlineEdits.between(removed: left.text, added: right.text)
            }

            rows.append(
                GitDiffRow(id: rows.count, content: .lines(left: left, right: right, inline: inline))
            )
        }
    }
}

/// A file's diff and the rows drawn from it.
///
/// The rows are built once, where the diff is read — on a background task —
/// rather than recomputed by the view. What the viewer holds.
struct GitDiffDocument: Equatable {
    let file: GitFileDiff
    let rows: [GitDiffRow]

    init(file: GitFileDiff) {
        self.file = file
        self.rows = GitDiffAlignment.rows(for: file)
    }
}
