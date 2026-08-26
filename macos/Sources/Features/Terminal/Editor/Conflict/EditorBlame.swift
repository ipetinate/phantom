import Foundation

/// Who last changed one line, and when.
///
/// The parsed answer rather than git's own words: the porcelain format is
/// stable and verbose, and every reader of this wants the same four facts.
struct EditorBlameLine: Equatable {
    let author: String
    let summary: String
    let commit: String
    let time: Date

    /// Whether git is describing an edit that has never been committed.
    ///
    /// Git reports one as an all-zero commit with the author "Not Committed
    /// Yet", which is the truthful answer and a useless thing to show a
    /// reader beside their own cursor.
    var isUncommitted: Bool {
        commit.allSatisfy { $0 == "0" } || author == "Not Committed Yet"
    }

    /// The sentence shown beside the line, in the shape every tool that does
    /// this uses: who, how long ago, and what they were doing.
    var ghostText: String {
        "\(author), \(EditorBlameLine.relative(time)) • \(summary)"
    }

    /// A rough age rather than a date.
    ///
    /// "3 months ago" is what the reader wants from a line they are looking
    /// at; the exact timestamp is a click away in the history and would cost
    /// the width of a date to show here.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Parsing `git blame --porcelain`.
///
/// Pure and separate from the running of it, because the parsing is the part
/// that can be wrong in a way nobody notices — a mis-parsed author is a name
/// beside somebody else's line.
enum EditorBlameParser {
    /// The header of one line's entry, followed by `key value` lines and then
    /// the source line prefixed with a tab. Only ever asked about one line, so
    /// the first entry is the answer.
    static func parse(porcelain output: String) -> EditorBlameLine? {
        var author: String?
        var summary: String?
        var commit: String?
        var timestamp: TimeInterval?

        for line in output.components(separatedBy: "\n") {
            if commit == nil, let first = line.split(separator: " ").first,
               first.count >= 7, first.allSatisfy(\.isHexDigit) {
                commit = String(first)
                continue
            }
            if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                timestamp = TimeInterval(line.dropFirst("author-time ".count))
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst("summary ".count))
            } else if line.hasPrefix("\t") {
                /// The source line itself ends the entry. Stopping here is
                /// what keeps a second entry — which `git blame` prints when
                /// asked about a range — from overwriting the first.
                break
            }
        }

        guard let author, let commit, let timestamp else { return nil }
        return EditorBlameLine(
            author: author,
            summary: summary ?? "",
            commit: commit,
            time: Date(timeIntervalSince1970: timestamp)
        )
    }
}
