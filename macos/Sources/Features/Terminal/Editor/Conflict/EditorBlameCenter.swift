import Combine
import Foundation

/// Answers "who last touched this line", one line at a time.
///
/// **One line and not the file.** Blaming a whole file is a real cost on a
/// large one and almost all of it is thrown away: what is shown is the line
/// the caret is on, and the caret is on one line. `git blame -L n,n` is the
/// same question scoped to the answer anybody will read.
///
/// The cache is what makes that affordable while somebody moves the caret. It
/// is keyed by path and line and emptied when the file is edited, because an
/// edit moves every line below it and a cached answer would then be attached
/// to the wrong one.
@MainActor
final class EditorBlameCenter: ObservableObject {
    static let shared = EditorBlameCenter()

    /// The line under the caret, for whichever editor asked last.
    @Published private(set) var current: EditorBlameLine?

    /// The path and line `current` describes, so a stale answer arriving
    /// after the caret moved can be dropped rather than shown.
    private var currentKey: Key?

    private struct Key: Hashable {
        let path: String
        let line: Int
    }

    private var cache: [Key: EditorBlameLine?] = [:]
    private var inFlight: Set<Key> = []

    /// Bounded so a session spent scrolling through a large file does not
    /// keep an entry per line of it. Cleared wholesale rather than by age:
    /// the entries are cheap to refetch and the bound is generous.
    private static let cacheLimit = 2_000

    private init() {}

    /// Asks about a line, and publishes the answer when it arrives.
    ///
    /// Passing nil is how the caret leaving a file takes the ghost text down.
    func request(path: String?, line: Int?) {
        guard let path, let line, line > 0 else {
            currentKey = nil
            current = nil
            return
        }

        let key = Key(path: path, line: line)
        currentKey = key

        if let cached = cache[key] {
            current = cached
            return
        }

        /// Nothing on screen while the answer is fetched, rather than the
        /// previous line's. Showing one line's history beside another line is
        /// worse than showing none.
        current = nil

        guard !inFlight.contains(key),
              let root = EditorChangeLookup.repositoryRoot(forPath: path)
        else { return }

        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let blame = Self.blame(path: path, line: line, in: root)
            await MainActor.run {
                self.inFlight.remove(key)
                if self.cache.count >= Self.cacheLimit { self.cache.removeAll() }
                self.cache[key] = blame

                /// Only if the caret is still where it was when this was
                /// asked. A slow `git blame` that lands after the reader has
                /// moved on would otherwise label the wrong line.
                guard self.currentKey == key else { return }
                self.current = blame
            }
        }
    }

    /// Forgets a file's answers. Called when its text changes: an edit moves
    /// every line below it, so every cached line number below the edit is now
    /// pointing at the wrong line.
    func invalidate(path: String) {
        cache = cache.filter { $0.key.path != path }
        if currentKey?.path == path {
            currentKey = nil
            current = nil
        }
    }

    /// `git blame` for one line, off the main actor.
    ///
    /// Uncommitted lines answer nil rather than "Not Committed Yet": the
    /// reader knows they have just typed it, and a label saying so is a label
    /// that appears exactly when it is least useful.
    private nonisolated static func blame(
        path: String,
        line: Int,
        in root: String
    ) -> EditorBlameLine? {
        let relative = EditorChangeLookup.relativePath(forPath: path, root: root) ?? path
        guard let output = GitCommand.output(
            ["blame", "--porcelain", "-L", "\(line),\(line)", "--", relative],
            in: root
        ) else { return nil }

        guard let parsed = EditorBlameParser.parse(porcelain: output),
              !parsed.isUncommitted
        else { return nil }
        return parsed
    }
}
