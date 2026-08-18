import Foundation

/// Turns the three pieces of git output a branch review is built from into
/// values: the commit list, the per-file line counts, and the per-file
/// status.
///
/// Pure, and separate from ``GitBranchReviewLoader`` on purpose. Every
/// claim about the *shape* of git's output can then be checked against a
/// fixture of that output, with no repository, no processes and no clock —
/// while the claims about git's *behaviour*, which a fixture can only
/// restate, stay in the loader's tests where a real `git` answers them.
enum GitBranchReviewParser {
    /// Separates the fields inside one commit record.
    ///
    /// A commit subject is arbitrary text: it can hold tabs, quotes, pipes,
    /// and any punctuation someone might have reached for as a separator.
    /// The unit separator is asked for by name in the format string
    /// (`%x1f`), so git writes a byte that a message realistically cannot
    /// contain, and the split is unambiguous instead of merely unlikely.
    static let fieldSeparator = "\u{1f}"

    /// Terminates one record. Git writes it for `-z`, and for `--numstat`
    /// and `--name-status` it also replaces the quoting that would
    /// otherwise mangle a non-ASCII path.
    static let recordSeparator = "\u{0}"

    /// The format `git log` is asked for: sha, subject, author, relative
    /// date, in that order.
    static let commitFormat = "%H%x1f%s%x1f%an%x1f%ar"

    /// One file's line counts, as `--numstat` reports them.
    struct LineCount: Equatable {
        /// nil when git printed `-`, which it does for a binary file.
        let added: Int?
        let removed: Int?

        var isBinary: Bool { added == nil }
    }

    /// One file's identity and fate, as `--name-status` reports them.
    struct FileEntry: Equatable {
        let path: String
        let previousPath: String?
        let status: GitFileDiff.Status
    }

    /// The commits, newest first, out of `git log -z --format=`.
    static func parseCommits(_ output: String) -> [GitReviewCommit] {
        records(in: output).compactMap { record in
            let fields = record.components(separatedBy: fieldSeparator)

            /// Four fields are asked for, and a subject that somehow
            /// contained the separator itself would produce more. Reading
            /// the sha from the front and the author and date from the back
            /// puts the surplus back where it came from instead of dropping
            /// the commit.
            guard fields.count >= 4 else { return nil }
            let sha = fields[0]
            guard !sha.isEmpty else { return nil }

            return GitReviewCommit(
                sha: sha,
                subject: fields[1..<(fields.count - 2)].joined(separator: fieldSeparator),
                author: fields[fields.count - 2],
                relativeDate: fields[fields.count - 1]
            )
        }
    }

    /// Line counts by path, out of `git diff --numstat -z`.
    ///
    /// Two shapes, and the second is why this cannot be a line-at-a-time
    /// parse. An ordinary entry is `added TAB removed TAB path NUL`. A
    /// rename or copy leaves the path field *empty* and follows with two
    /// more NUL-terminated fields, the old path and the new one — so the
    /// record boundary and the field boundary are the same byte, and the
    /// only way through is to consume tokens with a cursor.
    static func parseNumstat(_ output: String) -> [String: LineCount] {
        let tokens = output.components(separatedBy: recordSeparator)
        var counts: [String: LineCount] = [:]
        var index = 0

        while index < tokens.count {
            let token = cleaned(tokens[index])
            index += 1
            if token.isEmpty { continue }

            /// A path may itself contain a tab, so only the first two
            /// separators are structure; everything after them is the path.
            let fields = token.components(separatedBy: "\t")
            guard fields.count >= 3 else { continue }

            let count = LineCount(added: Int(fields[0]), removed: Int(fields[1]))
            let path = fields[2...].joined(separator: "\t")

            if path.isEmpty {
                guard index + 1 < tokens.count else { break }
                let renamed = tokens[index + 1]
                index += 2
                guard !renamed.isEmpty else { continue }
                counts[renamed] = count
            } else {
                counts[path] = count
            }
        }

        return counts
    }

    /// Files and their statuses, out of `git diff --name-status -z`.
    ///
    /// `R` and `C` carry a similarity score (`R100`) and are followed by
    /// two paths rather than one; everything else is a bare letter and one
    /// path.
    static func parseNameStatus(_ output: String) -> [FileEntry] {
        let tokens = output.components(separatedBy: recordSeparator)
        var entries: [FileEntry] = []
        var index = 0

        while index < tokens.count {
            let code = cleaned(tokens[index])
            index += 1
            guard let letter = code.first else { continue }

            if letter == "R" || letter == "C" {
                guard index + 1 < tokens.count else { break }
                let previous = tokens[index]
                let path = tokens[index + 1]
                index += 2
                guard !path.isEmpty else { continue }
                entries.append(
                    FileEntry(
                        path: path,
                        previousPath: previous.isEmpty ? nil : previous,
                        status: letter == "R" ? .renamed : .copied
                    )
                )
            } else {
                guard index < tokens.count else { break }
                let path = tokens[index]
                index += 1
                guard !path.isEmpty else { continue }
                entries.append(
                    FileEntry(path: path, previousPath: nil, status: status(for: letter))
                )
            }
        }

        return entries
    }

    /// The two halves joined into the file list.
    ///
    /// `--name-status` decides membership and order: it is the side that
    /// knows what happened to a file, and a status with no counts is still
    /// a row worth drawing — a pure rename has no counts at all, and a file
    /// git counts nothing in is exactly the binary case the model already
    /// has a word for.
    static func files(nameStatus: String, numstat: String) -> [GitReviewFile] {
        let counts = parseNumstat(numstat)

        return parseNameStatus(nameStatus).map { entry in
            let count = counts[entry.path]
            return GitReviewFile(
                path: entry.path,
                previousPath: entry.previousPath,
                status: entry.status,
                addedLines: count?.added,
                removedLines: count?.removed
            )
        }
    }

    /// Git's status letters, in the diff viewer's vocabulary.
    ///
    /// `T` is a type change — a file replaced by a symlink, or the reverse.
    /// It has no word of its own here and is reported as a modification,
    /// which is what it is to a reader: the path is still there and its
    /// content is not what it was. Anything unrecognized lands there too,
    /// rather than dropping the file out of a list that claims to be
    /// complete.
    private static func status(for letter: Character) -> GitFileDiff.Status {
        switch letter {
        case "A": return .added
        case "D": return .deleted
        default: return .modified
        }
    }

    /// Whole records, with git's separators and any stray newline gone.
    private static func records(in output: String) -> [String] {
        output.components(separatedBy: recordSeparator)
            .map(cleaned)
            .filter { !$0.isEmpty }
    }

    /// Trims only line breaks, and only at the ends.
    ///
    /// A record can arrive with the newline of whatever printed before it
    /// still attached. Trimming whitespace instead would eat the leading
    /// spaces of a path that has them, and git does not quote them under
    /// `-z`.
    private static func cleaned(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }
}
