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
                /// A removal and an insertion at the same position. The
                /// difference pairs them, and the pairing alone does not say
                /// whether the reader rewrote a line or typed a new one into
                /// a region that had already changed — so the two lines are
                /// compared rather than assumed related. See `isRewrite`.
                marks[currentIndex + 1] = isRewrite(current[currentIndex], base[baseIndex])
                    ? .changed
                    : .added
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
                /// Lines left from the boundary this line now sits against.
                /// The line itself is untouched — it is only carrying the
                /// mark, which is why `.removed` is drawn on its top edge
                /// rather than beside its number.
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

    /// Whether `line` is a rewrite of `was`, rather than something new that
    /// happens to sit where `was` used to.
    ///
    /// **Why the pairing cannot answer this.** `CollectionDifference` finds a
    /// minimal edit script; when a run of lines changes, it pairs removals
    /// with insertions by position, and a brand-new line typed inside that
    /// run gets paired with whatever removal is going spare. Reported by a
    /// reader who typed `<WD` on a fresh line inside a block they had already
    /// reformatted, and watched it come back marked as a change to a line it
    /// had nothing to do with.
    ///
    /// So the texts are compared. Two heuristics, both cheap, and both about
    /// the same thing — does this line still look like the one it replaced:
    ///
    /// - A shared leading run. Editing a line usually keeps its beginning:
    ///   its indentation, its keyword, the name being assigned. Requiring a
    ///   few characters past the indentation is what stops every line in an
    ///   indented block from looking related to every other.
    /// - Failing that, enough shared words. A line whose tokens are mostly
    ///   the tokens of the old one is a rewrite however much its shape moved;
    ///   a line that shares nothing but a bracket is not.
    ///
    /// Wrong in the reader's favour when it is wrong: an unrecognised rewrite
    /// is marked `added`, which says "this line is not in the commit" — true
    /// of a rewrite as well. The failure it avoids is the opposite one, where
    /// a new line is described as a change to something the reader never saw.
    static func isRewrite(_ line: String, _ was: String) -> Bool {
        let new = line.trimmingCharacters(in: .whitespaces)
        let old = was.trimmingCharacters(in: .whitespaces)

        guard !new.isEmpty, !old.isEmpty else { return new.isEmpty == old.isEmpty }
        if new == old { return true }

        let shared = zip(new, old).prefix { $0 == $1 }.count
        if shared >= minimumSharedPrefix { return true }

        let newWords = Set(new.split(whereSeparator: isTokenBoundary))
        let oldWords = Set(old.split(whereSeparator: isTokenBoundary))
        guard !newWords.isEmpty, !oldWords.isEmpty else { return false }

        let overlap = Double(newWords.intersection(oldWords).count)
        return overlap / Double(min(newWords.count, oldWords.count)) >= minimumSharedWords
    }

    /// How many characters two lines must open with to count as one edited.
    ///
    /// Four, measured against the alternative: at two, `</div>` and `</p>`
    /// pair up, and every closing tag in a template looks like a rewrite of
    /// every other. At eight, renaming a variable at the start of a line stops
    /// counting as an edit to it, which is the commonest edit there is.
    private static let minimumSharedPrefix = 4

    /// What fraction of the shorter line's words must be shared.
    ///
    /// Half. A rewrite that keeps half its vocabulary is recognisably the same
    /// line reworded; below that it is a different statement that happens to
    /// mention some of the same names.
    private static let minimumSharedWords = 0.5

    private static func isTokenBoundary(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && character != "_"
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

    /// The lines whose **text** differs from the committed file.
    ///
    /// Not derivable from ``marks(current:base:)``, and that is the whole
    /// reason this exists. The glyph answers "what should the margin draw",
    /// and it says `-` for two different things: a line that was changed in
    /// place, and a line that survived a deletion which happened at it. The
    /// first is the reader's own text; the second is somebody's committed
    /// line, unchanged, wearing a mark about its neighbour.
    ///
    /// `git blame` has to tell those apart, because it answers by line
    /// *number* against the file on disk: asked about a line the reader
    /// changed, it names whoever last touched that number in the commit — a
    /// real person with nothing to do with what is on screen. Asked about the
    /// surviving line, it is still right.
    ///
    /// So this reports insertions and in-place changes and nothing else. An
    /// earlier version of the ghost text filtered `marks` for `.added`, which
    /// covered a line typed on a new row and missed every line edited in
    /// place — the commonest case, and the one that was reported.
    static func changedLines(current: [String], base: [String]) -> Set<Int> {
        guard !base.isEmpty, current.count <= lineBudget, base.count <= lineBudget else {
            return []
        }

        let difference = current.difference(from: base)
        let inserted = Set(difference.insertions.map(offset))
        let removed = Set(difference.removals.map(offset))

        var changed: Set<Int> = []
        var baseIndex = 0
        var currentIndex = 0

        while baseIndex < base.count || currentIndex < current.count {
            let isRemoved = baseIndex < base.count && removed.contains(baseIndex)
            let isInserted = currentIndex < current.count && inserted.contains(currentIndex)

            switch (isRemoved, isInserted) {
            case (true, true), (false, true):
                changed.insert(currentIndex + 1)
                if isRemoved { baseIndex += 1 }
                currentIndex += 1

            case (true, false):
                baseIndex += 1

            case (false, false):
                baseIndex += 1
                currentIndex += 1
            }
        }
        return changed
    }
}
