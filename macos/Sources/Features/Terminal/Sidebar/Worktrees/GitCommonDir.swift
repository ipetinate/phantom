import Foundation

/// Finds the main checkout that a repository root shares its object store
/// with, by reading files rather than by running git.
///
/// Every worktree of a repository has to agree on one key, or the panel
/// shows the same repository several times over with a different list under
/// each name. The main checkout's root is that key: git keeps exactly one
/// per object store, and every linked worktree can find it.
///
/// Nothing here shells out, and that is the requirement rather than an
/// optimisation. The resolver sits on the path taken by the sidebar's 5s
/// metadata timer, which reaches `SidebarTabManager.gitInfo` — documented
/// there as walking up to `.git` and reading `HEAD` directly, *no git
/// execution*. `git rev-parse --git-common-dir` would answer this in one
/// line and cost a process spawn per tab per tick, on a timer, forever.
/// The files it would read are the same ones read here.
enum GitCommonDir {
    /// The main checkout's root for a repository root, or `nil` when there
    /// isn't one to be had.
    ///
    /// `repoRoot` is a root as `SidebarTabManager.gitInfo` resolves it: the
    /// folder holding `.git`, whether that `.git` is a directory or a file.
    ///
    /// Three shapes, in the order they are recognised:
    ///
    /// 1. `.git` is a directory — this *is* the main checkout, returned as is.
    /// 2. `.git` is a file — a linked worktree, or a submodule. Its
    ///    `gitdir:` line points at the administrative directory; that
    ///    directory's `commondir` file points at the shared git directory,
    ///    and the shared git directory's parent is the main checkout.
    /// 3. Anything else — no `.git` at all, an unreadable one, or a
    ///    submodule, all of which have no main checkout in this repository's
    ///    sense.
    ///
    /// A shared git directory whose last component is not `.git` belongs to
    /// a **bare** repository, which has no checkout to strip a `.git` off.
    /// That path is returned unchanged and callers treat it as bare.
    nonisolated static func resolve(from repoRoot: String, fileManager: FileManager = .default) -> String? {
        guard !repoRoot.isEmpty else { return nil }
        let dotGit = (repoRoot as NSString).appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return repoRoot }

        guard let pointer = readGitDir(at: dotGit, relativeTo: repoRoot, fileManager: fileManager) else { return nil }

        guard !isSubmodule(pointer) else { return nil }

        guard let common = commonDir(of: pointer, fileManager: fileManager) ?? fallbackCommonDir(of: pointer)
        else { return nil }

        guard (common as NSString).lastPathComponent == ".git" else { return common }
        return (common as NSString).deletingLastPathComponent
    }

    /// Whether an administrative directory belongs to a submodule.
    ///
    /// A submodule's git directory lives under the superproject's
    /// `.git/modules/<name>`, so its "main checkout" would be the
    /// superproject — a different repository, with a different object store
    /// and a worktree list of its own. Better to have no answer than the
    /// wrong repository's.
    private static func isSubmodule(_ gitDir: String) -> Bool {
        gitDir.contains("/modules/")
    }

    /// The `gitdir: <path>` line of a `.git` file, resolved to an absolute
    /// path.
    ///
    /// Same shape `SidebarTabManager.gitInfo` handles: git writes an
    /// absolute path when it created the worktree itself and a relative one
    /// when the pair was moved or `--relative-paths` was asked for, and a
    /// relative path is relative to the folder holding the `.git` file.
    private static func readGitDir(
        at dotGit: String,
        relativeTo repoRoot: String,
        fileManager: FileManager
    ) -> String? {
        guard let data = fileManager.contents(atPath: dotGit),
              let content = String(data: data, encoding: .utf8),
              content.hasPrefix("gitdir:")
        else { return nil }

        let raw = content.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return absolute(raw, relativeTo: repoRoot)
    }

    /// The shared git directory a worktree's administrative directory names.
    ///
    /// `commondir` is the pointer git itself follows, so it is the authority
    /// here too: it is written by `git worktree add`, updated by
    /// `git worktree move` and `repair`, and holds either an absolute path
    /// or one relative to the administrative directory (`../..` in the
    /// ordinary layout).
    private static func commonDir(of gitDir: String, fileManager: FileManager) -> String? {
        let pointer = (gitDir as NSString).appendingPathComponent("commondir")
        guard let data = fileManager.contents(atPath: pointer),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return absolute(raw, relativeTo: gitDir)
    }

    /// What the layout says when `commondir` is missing or unreadable.
    ///
    /// An administrative directory sits at `<main>/.git/worktrees/<name>`,
    /// so the shared git directory is the `.git` component itself. Only the
    /// standard layout is recovered this way — a bare repository's
    /// `<repo>.git/worktrees/<name>` has no `.git` component to find, and
    /// guessing one would invent a checkout that does not exist.
    private static func fallbackCommonDir(of gitDir: String) -> String? {
        let marker = "/.git/worktrees/"
        guard let range = gitDir.range(of: marker) else { return nil }
        return String(gitDir[gitDir.startIndex..<range.lowerBound]) + "/.git"
    }

    private static func absolute(_ path: String, relativeTo base: String) -> String {
        if path.hasPrefix("/") { return collapsing(path) }
        return collapsing(base + "/" + path)
    }

    /// Resolves `.` and `..` lexically, and touches nothing else.
    ///
    /// Foundation's own standardisation cannot be used here, and this is the
    /// subtlest thing in the file. Both `URL.standardizedFileURL` and
    /// `NSString.standardizingPath` special-case the `/private` prefix and
    /// rewrite `/private/var/…` to `/var/…` — the same directory under a
    /// different spelling. Git prints the `/private` form, and this
    /// resolver's whole job is to produce the key that git's own paths and
    /// the tabs' working directories are compared against. A resolver that
    /// quietly restyles the answer produces a key nothing matches, a
    /// repository listed twice, and a worktree that belongs to neither
    /// entry.
    ///
    /// Lexical on purpose, symlinks included: the caller was handed a path
    /// by git or by the sidebar, and resolving it further would move it away
    /// from the spelling they use.
    private static func collapsing(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [String] = []

        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append("..")
                }
            default:
                components.append(String(component))
            }
        }

        let joined = components.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }
}
