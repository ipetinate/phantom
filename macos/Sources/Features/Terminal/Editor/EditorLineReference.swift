import Foundation

/// The `@path:line` reference the editor hands to an agent's prompt.
///
/// Pure, because the two judgements in here are exactly the kind that rot
/// when they live in a view: which lines a selection *touches*, and what the
/// path is relative to. The rest — which terminal, how the text is typed — is
/// the host's business.
enum EditorLineReference {
    /// The 1-based lines the selection covers.
    ///
    /// A selection that ends exactly at the start of a line has not touched
    /// that line — it stopped on the terminator of the one before. Same rule
    /// as `CodeLineMove.blockRange`, and for the same reason: selecting one
    /// whole line by dragging into the next must reference one line, not two.
    nonisolated static func lines(in text: NSString, selection: NSRange) -> (start: Int, end: Int) {
        let start = min(selection.location, text.length)
        var end = min(NSMaxRange(selection), text.length)

        if selection.length > 0, end > start {
            let last = text.character(at: end - 1)
            if last == 0x0A || last == 0x0D { end -= 1 }
        }

        let startLine = lineNumber(at: start, in: text)
        let endLine = end > start ? lineNumber(at: max(start, end - 1), in: text) : startLine
        return (startLine, max(startLine, endLine))
    }

    /// The reference itself: `@rel/path:12`, or `@rel/path:12-24` for a
    /// range.
    ///
    /// Relative to the terminal's own cwd, because that is where the agent
    /// resolves what it reads. A file outside the cwd keeps its absolute
    /// path — a `../`-laden guess would be resolved against whatever the
    /// agent's idea of the workspace is, and a wrong file referenced
    /// confidently is worse than a long one.
    ///
    /// The `@` is Claude Code's file-reference convention; the other agents
    /// read the same string as plain text and lose nothing by it.
    nonisolated static func reference(
        filePath: String,
        lines: (start: Int, end: Int),
        cwd: String?
    ) -> String {
        let path: String
        if let cwd,
           let relative = EditorChangeLookup.relativePath(forPath: filePath, root: cwd) {
            path = relative
        } else {
            path = filePath
        }

        let suffix = lines.start == lines.end
            ? ":\(lines.start)"
            : ":\(lines.start)-\(lines.end)"
        return "@" + path + suffix
    }

    /// Counted by walking the terminators, because that is the whole
    /// definition: line N starts after the (N-1)th terminator. `\r\n` is one
    /// terminator, not two.
    private nonisolated static func lineNumber(at offset: Int, in text: NSString) -> Int {
        let bound = min(offset, text.length)
        var line = 1
        var index = 0
        while index < bound {
            let character = text.character(at: index)
            if character == 0x0A {
                line += 1
            } else if character == 0x0D {
                line += 1
                if index + 1 < bound, text.character(at: index + 1) == 0x0A { index += 1 }
            }
            index += 1
        }
        return line
    }
}
