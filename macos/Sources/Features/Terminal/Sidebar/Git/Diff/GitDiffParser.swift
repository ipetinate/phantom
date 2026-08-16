import Foundation

/// Turns `git diff` output into ``GitFileDiff`` values.
///
/// Pure: it takes a string and returns a model, runs nothing, and touches
/// no filesystem. Every rule below was checked against real git output
/// rather than against the manual, because the places this format bites are
/// exactly the ones the manual glosses over.
///
/// The load-bearing decision is that hunks are consumed **by the counts in
/// their own header**, not by looking for the next line that starts with
/// `diff` or `@@`. A diff of a patch file has content lines that begin with
/// `+`, `-`, `@@` and `diff --git`, and any parser that scans for those
/// markers cuts the hunk in half at the first one. Git's counts are always
/// right, so counting is both simpler and correct.
enum GitDiffParser {
    /// Parses the whole of a `git diff`, which may describe several files.
    nonisolated static func parse(unified output: String) -> [GitFileDiff] {
        var lines = splitLines(output)

        // Output ends with a newline, so the split leaves a phantom empty
        // element. Left in, a truncated hunk would consume it as an empty
        // context line.
        if lines.last?.isEmpty == true { lines.removeLast() }

        var files: [GitFileDiff] = []
        var index = 0

        while index < lines.count {
            guard isFileHeader(lines[index]) else {
                index += 1
                continue
            }

            let (file, next) = parseFile(lines, from: index)
            if let file { files.append(file) }

            // Never trust the sub-parser to advance; a header it cannot
            // make sense of would otherwise spin here forever.
            index = max(next, index + 1)
        }

        return files
    }

    /// Splits on newlines *by Unicode scalar*, which for once is not
    /// pedantry.
    ///
    /// Swift counts `\r\n` as a single `Character` — one grapheme cluster,
    /// not two — and a `Character` of `\r\n` is not equal to one of `\n`.
    /// So `split(separator: "\n")` finds no separators at all in the diff
    /// of a CRLF file, hands back the entire diff as one line, and the
    /// viewer shows a single context row containing the whole patch. It
    /// fails silently and completely, on every file with Windows line
    /// endings.
    ///
    /// Splitting scalars matches the `\n` and leaves the `\r` where it
    /// belongs: at the end of the line's content, which is where it is a
    /// real difference worth drawing.
    private static func splitLines(_ text: String) -> [String] {
        text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    private static func isFileHeader(_ line: String) -> Bool {
        line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ")
    }

    // MARK: One file

    private static func parseFile(_ lines: [String], from start: Int) -> (GitFileDiff?, Int) {
        let header = lines[start]
        let isCombined = header.hasPrefix("diff --cc ") || header.hasPrefix("diff --combined ")

        var oldPath: String?
        var newPath: String?
        var renameFrom: String?
        var renameTo: String?
        var copyFrom: String?
        var copyTo: String?
        var oldMode: String?
        var newMode: String?
        var isNewFile = false
        var isDeletedFile = false
        var isBinary = false
        var hunks: [GitDiffHunk] = []

        var index = start + 1

        while index < lines.count {
            let line = lines[index]

            if isFileHeader(line) { break }

            if line.hasPrefix("@@") {
                // A combined diff's body carries one marker column per
                // merge parent (`@@@ -1,2 -1,2 +1,6 @@@`, then two markers
                // per line), so reading it as a two-column hunk mislabels
                // every line in it. Everything worth having — the paths —
                // is already above this point.
                if isCombined { break }

                guard let parsed = parseHunkHeader(line) else {
                    index += 1
                    continue
                }

                let (hunk, next) = parseHunk(lines, from: index, header: parsed)
                hunks.append(hunk)
                index = next
                continue
            }

            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
                index += 1
                continue
            }

            // Order matters: "new file mode" also has the prefix "new".
            if let mode = value(of: "new file mode ", in: line) {
                isNewFile = true
                newMode = mode
            } else if let mode = value(of: "deleted file mode ", in: line) {
                isDeletedFile = true
                oldMode = mode
            } else if let mode = value(of: "old mode ", in: line) {
                oldMode = mode
            } else if let mode = value(of: "new mode ", in: line) {
                newMode = mode
            } else if let path = value(of: "rename from ", in: line) {
                renameFrom = unquote(path)
            } else if let path = value(of: "rename to ", in: line) {
                renameTo = unquote(path)
            } else if let path = value(of: "copy from ", in: line) {
                copyFrom = unquote(path)
            } else if let path = value(of: "copy to ", in: line) {
                copyTo = unquote(path)
            } else if let path = value(of: "--- ", in: line) {
                oldPath = strip(prefix: "a/", from: headerPath(path))
            } else if let path = value(of: "+++ ", in: line) {
                newPath = strip(prefix: "b/", from: headerPath(path))
            }

            index += 1
        }

        let fallback = headerPaths(header, isCombined: isCombined)
        let old = renameFrom ?? copyFrom ?? oldPath ?? fallback.old
        let new = renameTo ?? copyTo ?? newPath ?? fallback.new

        // A deletion has no new path and an addition no old one, so the
        // surviving side is the one to name the file by.
        guard let path = new ?? old else { return (nil, index) }

        let status: GitFileDiff.Status
        if renameTo != nil {
            status = .renamed
        } else if copyTo != nil {
            status = .copied
        } else if isNewFile || (oldPath == nil && newPath != nil) {
            status = .added
        } else if isDeletedFile || (newPath == nil && oldPath != nil) {
            status = .deleted
        } else {
            status = .modified
        }

        let previous = (status == .renamed || status == .copied) ? old : nil

        return (
            GitFileDiff(
                path: path,
                previousPath: previous == path ? nil : previous,
                status: status,
                oldMode: oldMode,
                newMode: newMode,
                isBinary: isBinary,
                isCombined: isCombined,
                hunks: hunks
            ),
            index
        )
    }

    // MARK: Hunks

    /// `@@ -oldStart,oldCount +newStart,newCount @@ heading`
    ///
    /// Either count may be missing, and missing means 1. The heading is
    /// free text that can itself contain `@@`, so it is everything after
    /// the *second* `@@` rather than everything after the last one.
    nonisolated static func parseHunkHeader(_ line: String) -> GitDiffHunk.Header? {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard trimmed.hasPrefix("@@ ") else { return nil }

        let afterOpening = trimmed.dropFirst(3)
        guard let closing = afterOpening.range(of: " @@") else { return nil }

        let ranges = afterOpening[..<closing.lowerBound].split(separator: " ")
        guard ranges.count == 2,
              ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
              let old = parseRange(ranges[0].dropFirst()),
              let new = parseRange(ranges[1].dropFirst())
        else { return nil }

        let heading = afterOpening[closing.upperBound...]
            .trimmingCharacters(in: .whitespaces)

        return GitDiffHunk.Header(
            oldStart: old.start,
            oldCount: old.count,
            newStart: new.start,
            newCount: new.count,
            heading: heading
        )
    }

    /// `12,7` or a bare `12`, which means one line.
    private static func parseRange(_ field: Substring) -> (start: Int, count: Int)? {
        let parts = field.split(separator: ",", maxSplits: 1)
        guard let start = Int(parts[0]) else { return nil }
        guard parts.count == 2 else { return (start, 1) }
        guard let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    /// Reads exactly as many lines as the header promises.
    ///
    /// - Parameter from: index of the `@@` line itself.
    /// - Returns: the hunk and the index of the first line after it.
    private static func parseHunk(
        _ lines: [String],
        from start: Int,
        header: GitDiffHunk.Header
    ) -> (GitDiffHunk, Int) {
        var body: [GitDiffLine] = []
        var oldNumber = header.oldStart
        var newNumber = header.newStart
        var consumedOld = 0
        var consumedNew = 0
        var index = start + 1

        while index < lines.count, consumedOld < header.oldCount || consumedNew < header.newCount {
            let raw = lines[index]

            // Git writes a lone space for an empty context line, but plenty
            // of tools that pass a patch around strip trailing whitespace
            // and leave nothing at all. It is still that context line.
            guard let marker = raw.first else {
                body.append(
                    GitDiffLine(
                        kind: .context,
                        text: "",
                        oldNumber: oldNumber,
                        newNumber: newNumber,
                        isEndOfFileWithoutNewline: false
                    )
                )
                oldNumber += 1
                newNumber += 1
                consumedOld += 1
                consumedNew += 1
                index += 1
                continue
            }

            let content = String(raw.dropFirst())

            switch marker {
            case " ":
                body.append(
                    GitDiffLine(
                        kind: .context,
                        text: content,
                        oldNumber: oldNumber,
                        newNumber: newNumber,
                        isEndOfFileWithoutNewline: false
                    )
                )
                oldNumber += 1
                newNumber += 1
                consumedOld += 1
                consumedNew += 1

            case "-":
                body.append(
                    GitDiffLine(
                        kind: .removed,
                        text: content,
                        oldNumber: oldNumber,
                        newNumber: nil,
                        isEndOfFileWithoutNewline: false
                    )
                )
                oldNumber += 1
                consumedOld += 1

            case "+":
                body.append(
                    GitDiffLine(
                        kind: .added,
                        text: content,
                        oldNumber: nil,
                        newNumber: newNumber,
                        isEndOfFileWithoutNewline: false
                    )
                )
                newNumber += 1
                consumedNew += 1

            case "\\":
                // `\ No newline at end of file` belongs to the line above
                // and counts toward neither side's total.
                markEndOfFileWithoutNewline(&body)

            default:
                // Nothing else can be inside a hunk. A patch whose counts
                // overshoot its body ends here rather than swallowing the
                // next file's header.
                return (GitDiffHunk(header: header, lines: body), index)
            }

            index += 1
        }

        // The marker for the final line arrives after the counts are met.
        if index < lines.count, lines[index].hasPrefix("\\") {
            markEndOfFileWithoutNewline(&body)
            index += 1
        }

        return (GitDiffHunk(header: header, lines: body), index)
    }

    private static func markEndOfFileWithoutNewline(_ body: inout [GitDiffLine]) {
        guard let last = body.last else { return }
        body[body.count - 1] = GitDiffLine(
            kind: last.kind,
            text: last.text,
            oldNumber: last.oldNumber,
            newNumber: last.newNumber,
            isEndOfFileWithoutNewline: true
        )
    }

    // MARK: Paths

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// The path out of a `---` or `+++` line.
    ///
    /// Git appends a tab after the path when the path contains a space —
    /// the unified-diff convention that makes `--- a/my file.txt` readable
    /// at all. Without cutting there, every path with a space acquires a
    /// trailing tab and stops matching the path the caller asked about.
    ///
    /// A path git had to quote (an embedded `"`, a control character, or
    /// any non-ASCII byte when `core.quotePath` is left on) arrives C-quoted
    /// instead, and is unescaped rather than cut.
    private static func headerPath(_ field: String) -> String? {
        if field.hasPrefix("\"") { return unquote(field) }

        let path = field.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return path == "/dev/null" ? nil : String(path)
    }

    private static func strip(prefix: String, from path: String?) -> String? {
        guard let path else { return nil }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Last-resort paths, from the `diff --git a/x b/x` line itself.
    ///
    /// Only reached when there are no `---`/`+++` lines to read instead — a
    /// binary file, or a mode change with no content. That line is
    /// genuinely ambiguous when a path contains a space, since nothing
    /// separates the two halves but a space of its own. Both halves are the
    /// same path in every case that gets here, so the split is placed where
    /// that comes out true.
    private static func headerPaths(_ line: String, isCombined: Bool) -> (old: String?, new: String?) {
        if isCombined {
            let prefix = line.hasPrefix("diff --cc ") ? "diff --cc " : "diff --combined "
            let path = unquote(String(line.dropFirst(prefix.count)))
            return (path, path)
        }

        guard line.hasPrefix("diff --git ") else { return (nil, nil) }
        let rest = String(line.dropFirst("diff --git ".count))

        if rest.hasPrefix("\"") {
            guard let split = endOfQuotedString(in: rest) else { return (nil, nil) }
            let first = unquote(String(rest[rest.startIndex..<split]))
            let second = rest[split...].dropFirst().trimmingCharacters(in: .whitespaces)
            return (strip(prefix: "a/", from: first), strip(prefix: "b/", from: unquote(second)))
        }

        // `a/P b/P` — the halves are equal, so their length follows from
        // the whole: two prefixes of two characters, one separating space.
        let characters = Array(rest)
        let pathLength = (characters.count - 5) / 2
        if pathLength >= 0,
           characters.count == 5 + pathLength * 2,
           rest.hasPrefix("a/"),
           characters[2 + pathLength] == " ",
           characters[(3 + pathLength)...(4 + pathLength)] == ["b", "/"] {
            let path = String(characters[2..<(2 + pathLength)])
            return (path, path)
        }

        // Unequal halves: the first ` b/` is the best guess available.
        guard let separator = rest.range(of: " b/") else { return (nil, nil) }
        return (
            strip(prefix: "a/", from: String(rest[rest.startIndex..<separator.lowerBound])),
            String(rest[separator.upperBound...])
        )
    }

    /// Index of the closing quote of a C-quoted string starting at index 0,
    /// skipping over escaped quotes.
    private static func endOfQuotedString(in text: String) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if text[index] == "\"" { return index }
            index = text.index(after: index)
        }
        return nil
    }

    /// Undoes git's C-style quoting.
    ///
    /// Octal escapes are per *byte*, not per character: `café.txt` comes
    /// back as `caf\303\251.txt`, two escapes for one letter. They have to
    /// be collected as bytes and decoded as UTF-8 at the end — decoding
    /// each one alone produces two replacement characters.
    nonisolated static func unquote(_ field: String) -> String {
        guard field.hasPrefix("\""), field.hasSuffix("\""), field.count >= 2 else { return field }

        let characters = Array(field.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                bytes.append(contentsOf: Array(String(characters[index]).utf8))
                index += 1
                continue
            }

            switch characters[index + 1] {
            case "n": bytes.append(0x0A); index += 2
            case "t": bytes.append(0x09); index += 2
            case "r": bytes.append(0x0D); index += 2
            case "a": bytes.append(0x07); index += 2
            case "b": bytes.append(0x08); index += 2
            case "f": bytes.append(0x0C); index += 2
            case "v": bytes.append(0x0B); index += 2
            case "\"": bytes.append(0x22); index += 2
            case "\\": bytes.append(0x5C); index += 2
            default:
                if index + 3 < characters.count,
                   let value = UInt8(String(characters[(index + 1)...(index + 3)]), radix: 8) {
                    bytes.append(value)
                    index += 4
                } else {
                    bytes.append(contentsOf: Array(String(characters[index]).utf8))
                    index += 1
                }
            }
        }

        // A path whose escapes do not decode as UTF-8 keeps the form git
        // printed. Unreadable is better than eight replacement characters
        // that match nothing.
        return String(bytes: bytes, encoding: .utf8) ?? field
    }
}
