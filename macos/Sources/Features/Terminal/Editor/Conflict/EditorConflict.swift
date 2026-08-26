import Foundation

/// One merge conflict, as git left it in the file.
///
/// Parsed rather than diffed: the markers are already in the text, and the
/// text is the only thing both this editor and `git` agree on. Reading them
/// means a resolution is an ordinary edit — undoable, savable, and visible to
/// anything else watching the file — instead of a private side channel that
/// has to be replayed onto disk.
///
/// ## The shapes git writes
///
/// The plain form is three markers:
///
///     <<<<<<< HEAD
///     what is here now
///     =======
///     what is arriving
///     >>>>>>> their-branch
///
/// With `merge.conflictstyle` set to `diff3` or `zdiff3` there is a fourth,
/// carrying the common ancestor:
///
///     <<<<<<< HEAD
///     what is here now
///     ||||||| merged common ancestors
///     what both sides started from
///     =======
///     what is arriving
///     >>>>>>> their-branch
///
/// Both are read. The ancestor is kept rather than skipped, because it is the
/// one section that answers "what changed on each side" — a reader who has it
/// can see that one side deleted a line and the other edited it, which the
/// two-way form cannot show.
struct EditorConflict: Equatable, Identifiable {
    /// Position in the file, counted from the top. Stable only for the text it
    /// was parsed from, which is why every resolution reparses.
    let id: Int

    /// What the `<<<<<<<` line says after the marker — `HEAD` most of the
    /// time, a commit subject during a rebase.
    let currentLabel: String

    /// What the `>>>>>>>` line says: the branch, tag or commit arriving.
    let incomingLabel: String

    /// The side that is already in the working tree.
    let current: [String]

    /// The common ancestor, present only in `diff3` and `zdiff3` styles.
    let base: [String]?

    /// The side being merged in.
    let incoming: [String]

    /// Zero-based line index of the `<<<<<<<` line, and of the `>>>>>>>` line.
    /// What the gutter and the action bar are positioned against.
    let startLine: Int
    let endLine: Int

    /// The whole block including its markers, as characters in the original
    /// text — the trailing newline of the `>>>>>>>` line included when there
    /// is one.
    ///
    /// It has to be included: a conflict where one side is empty resolves to
    /// nothing at all, and a range stopping short of the newline would leave a
    /// blank line behind on every such resolution.
    let range: NSRange

    /// Whether this block ends the file with no newline after it. The one case
    /// where a resolution must not append one, since doing so would change a
    /// file the reader never asked to change.
    let endsWithoutNewline: Bool

    /// Which side the reader kept.
    enum Choice: String, CaseIterable {
        case current
        case incoming
        case both
        case base

        /// What the button says. `current` and `incoming` deliberately do not
        /// name the branch: the label is `HEAD` most of the time, and a button
        /// reading "Accept HEAD" tells a reader less than one reading "Accept
        /// Current" while being longer.
        var title: String {
            switch self {
            case .current: return "Accept Current"
            case .incoming: return "Accept Incoming"
            case .both: return "Accept Both"
            case .base: return "Accept Base"
            }
        }
    }

    /// The lines a choice keeps, in the order it keeps them.
    ///
    /// `both` is current then incoming, which is the order they appear in the
    /// file and the order every other merge tool uses. The ancestor is never
    /// part of `both`: it is what the two sides diverged *from*, so keeping it
    /// alongside them would put a third, older copy into the result.
    func lines(for choice: Choice) -> [String] {
        switch choice {
        case .current: return current
        case .incoming: return incoming
        case .both: return current + incoming
        case .base: return base ?? []
        }
    }

    /// The text that replaces ``range`` when the reader picks a side.
    ///
    /// Ends with a newline whenever it keeps anything, because the range it
    /// replaces ended with one. Empty when the choice keeps nothing, which is
    /// how a conflict between a deletion and an edit resolves to a deletion
    /// rather than to a blank line.
    func replacement(for choice: Choice) -> String {
        let kept = lines(for: choice)
        guard !kept.isEmpty else { return "" }
        let body = kept.joined(separator: "\n")
        return endsWithoutNewline ? body : body + "\n"
    }

    /// Whether this block has an ancestor section to offer.
    var hasBase: Bool { base != nil }

    /// The line ranges each part of the block occupies, for whatever draws
    /// behind them. Zero-based and half-open, in the file the block was
    /// parsed from.
    ///
    /// Derived here rather than by the view because the arithmetic is the
    /// parser's: which line the ancestor starts on depends on whether there
    /// is one, and getting that wrong paints the wrong half of a conflict.
    struct Sections {
        let currentLines: Range<Int>
        let baseLines: Range<Int>?
        let incomingLines: Range<Int>

        /// The three or four lines that are markers rather than content.
        let markerLines: [Int]
    }

    var sections: Sections {
        let currentStart = startLine + 1
        let currentEnd = currentStart + current.count

        var markers = [startLine, endLine]
        var baseRange: Range<Int>?
        var separator = currentEnd

        if let base {
            markers.append(currentEnd)
            let baseStart = currentEnd + 1
            baseRange = baseStart..<(baseStart + base.count)
            separator = baseStart + base.count
        }
        markers.append(separator)

        let incomingStart = separator + 1
        return Sections(
            currentLines: currentStart..<currentEnd,
            baseLines: baseRange,
            incomingLines: incomingStart..<(incomingStart + incoming.count),
            markerLines: markers.sorted()
        )
    }

    /// The choices worth showing for this block.
    ///
    /// `base` only when there is one, and never when it is empty: a button
    /// that resolves to nothing reads as "delete all of this", which is what
    /// the other three are for and not what the ancestor means.
    var choices: [Choice] {
        var offered: [Choice] = [.current, .incoming, .both]
        if let base, !base.isEmpty { offered.append(.base) }
        return offered
    }
}
