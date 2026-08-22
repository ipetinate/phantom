import Foundation

/// Where a new worktree goes.
///
/// One layout, `<managedRoot>/<repo>-<branch>`, flat and self-describing.
///
/// Flat rather than nested under a repository folder, and the reason is the
/// shell prompt: a prompt shows the last path component, so a nested
/// `worktrees/react-ts/feat-menu` says only `feat-menu` and leaves "which
/// project" unanswered dozens of times a day, while `react-ts-feat-menu`
/// answers it every time. The folder is browsed rarely; the prompt is read
/// constantly.
///
/// Pure path arithmetic plus the two filesystem questions it cannot answer
/// without looking: whether the folder it wants already belongs to another
/// repository, and whether it is already in use.
enum WorktreePath {
    /// The folder a worktree for `branch` should be created in.
    ///
    /// The branch name is not a path: `feature/x` is one ref with a slash in
    /// it, and using it verbatim would nest a folder `x` inside a folder
    /// `feature` — where a second branch `feature/y` lands beside it and the
    /// two are no longer one directory per worktree. Slashes become dashes.
    ///
    /// The path is returned whether or not anything is there. Git decides
    /// whether the checkout can happen, and it is stricter than any check
    /// here could be; ``isOccupied(_:fileManager:)`` exists so the flow can
    /// say something kinder first.
    nonisolated static func derive(
        managedRoot: String,
        mainCheckout: String,
        branch: String,
        fileManager: FileManager = .default
    ) -> String {
        let name = folderName(mainCheckout: mainCheckout, branch: branch)
        return available(
            name: name,
            managedRoot: managedRoot,
            mainCheckout: mainCheckout,
            fileManager: fileManager
        )
    }

    /// `<repo>-<branch>`, the whole identity of a worktree in one component.
    nonisolated static func folderName(mainCheckout: String, branch: String) -> String {
        let repoName = (mainCheckout as NSString).lastPathComponent
        return "\(repoName)-\(sanitize(branch))"
    }

    /// The repository a worktree folder belongs to, for the sidebar's chip.
    ///
    /// Read from the checkout rather than parsed back out of the folder
    /// name: a repository called `api-v2` with a branch `fix` produces
    /// `api-v2-fix`, and splitting that on dashes cannot know where the
    /// repository stops.
    nonisolated static func repoName(mainCheckout: String) -> String {
        (mainCheckout as NSString).lastPathComponent
    }

    /// Whether creating a worktree at this path would fail for want of an
    /// empty directory.
    ///
    /// Counts every child, hidden ones included. A folder holding nothing
    /// but a `.DS_Store` that Finder left behind is still one git refuses,
    /// so treating it as free would buy a friendlier message followed by
    /// the failure it promised wouldn't happen.
    nonisolated static func isOccupied(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return true }
        let children = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        return !children.isEmpty
    }

    /// A branch name as a single path component.
    nonisolated static func sanitize(_ branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// `<managedRoot>/<name>`, or a numbered sibling when that folder is
    /// demonstrably another repository's.
    ///
    /// Repository names are not unique — a fork and its upstream, or the
    /// same project cloned twice under different parents, are both called
    /// `phantom`, and with a flat layout their `phantom-main` folders want
    /// the same name. So an existing folder is reused only when it can be
    /// shown to belong to this repository: it resolves, through
    /// ``GitCommonDir``, back to the same main checkout. One that answers a
    /// different checkout is somebody else's and the search moves to `-2`.
    /// One that answers nothing — empty, or holding something that isn't a
    /// worktree — is claimed, since there is no evidence against it and
    /// inventing a `-2` beside an empty folder is the worse mistake.
    private static func available(
        name: String,
        managedRoot: String,
        mainCheckout: String,
        fileManager: FileManager
    ) -> String {
        var candidate = (managedRoot as NSString).appendingPathComponent(name)

        for suffix in 2...suffixLimit {
            guard fileManager.fileExists(atPath: candidate) else { return candidate }
            guard let owner = GitCommonDir.resolve(from: candidate, fileManager: fileManager),
                  owner != mainCheckout
            else { return candidate }
            candidate = (managedRoot as NSString).appendingPathComponent("\(name)-\(suffix)")
        }

        return candidate
    }

    /// Where the search gives up and reuses the last name it tried. Nobody
    /// has 99 same-named repositories; a caller with a filesystem that
    /// lies about `fileExists` shouldn't spin forever either.
    private static let suffixLimit = 99
}
