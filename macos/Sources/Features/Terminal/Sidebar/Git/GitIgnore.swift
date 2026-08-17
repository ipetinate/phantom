import Foundation

/// Appending a path to a repository's `.gitignore`.
///
/// The decisions are separated from the writing because the decisions are
/// where this goes wrong — what a directory's line looks like, and whether
/// the file already covers the path — and neither needs a filesystem to be
/// checked.
enum GitIgnore {
    /// The line to append for a repository-relative path.
    ///
    /// Anchored with a leading `/` so it means *this* path rather than every
    /// path that ends this way: without it, ignoring `src/config.ts` also
    /// ignores `vendor/lib/src/config.ts`, which is a surprise nobody asked
    /// for and one that is hard to notice later.
    ///
    /// A directory gets a trailing slash, which is git's own way of saying
    /// "the directory and everything in it" and stops the pattern from also
    /// matching a *file* of that name elsewhere.
    static func line(forRelativePath path: String, isDirectory: Bool) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }

        /// Escaped so a name git would read as a pattern is taken literally.
        /// A file really can be called `report[1].csv`, and unescaped it
        /// would ignore `report1.csv` and not itself.
        let escaped = trimmed
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")

        return isDirectory ? "/\(escaped)/" : "/\(escaped)"
    }

    /// Whether the file already has this exact line.
    ///
    /// Deliberately only an exact match. Deciding whether an existing
    /// *pattern* already covers a path means implementing gitignore matching
    /// — negations, `**`, precedence — and getting that subtly wrong would
    /// silently decline to add an entry the reader asked for. A duplicate
    /// line is harmless; a missing one is the bug.
    static func alreadyContains(_ line: String, in contents: String) -> Bool {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == line }
    }

    /// The contents the file should have after appending, or nil when the
    /// line is already there and nothing should be written.
    ///
    /// Returns whole contents rather than appending in place so the caller
    /// writes once and the newline handling lives in one place: a
    /// `.gitignore` whose last line has no terminator would otherwise get
    /// the new entry glued onto it.
    static func appending(_ line: String, to contents: String) -> String? {
        guard !line.isEmpty, !alreadyContains(line, in: contents) else { return nil }
        guard !contents.isEmpty else { return line + "\n" }

        return contents.hasSuffix("\n")
            ? contents + line + "\n"
            : contents + "\n" + line + "\n"
    }

    /// Adds a path to the repository's `.gitignore`, creating the file if it
    /// is not there.
    ///
    /// - Returns: false when nothing was written — the entry was already
    ///   present, or the write failed. The caller decides whether that is
    ///   worth saying out loud; silently reporting success would be worse.
    @discardableResult
    static func add(relativePath: String, isDirectory: Bool, inRepositoryAt root: String) -> Bool {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        guard let updated = appending(
            line(forRelativePath: relativePath, isDirectory: isDirectory),
            to: existing
        ) else { return false }

        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
