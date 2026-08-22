import Foundation
@testable import Ghostty
import Testing

/// Which worktrees `WorktreeFindings` offers to clean up.
///
/// Every finding here ends in an offer to delete a folder and a branch, so
/// the tests are mostly about what must *not* be offered: the main checkout,
/// a detached worktree, a worktree outside the managed root, and — the one
/// that decides where a rule lives — a branch sitting at the base's tip,
/// which is `WorktreeCenter`'s job to have excluded and not this file's.
struct WorktreeFindingsTests {
    private let managedRoot = "/Users/dev/.phantom/worktrees"

    private func worktree(
        _ path: String,
        branch: String? = "feat/x",
        isMain: Bool = false,
        head: String? = "9f0e1b7",
        prunable: String? = nil
    ) -> GitWorktree {
        GitWorktree(
            path: path,
            head: head,
            branch: branch,
            isMain: isMain,
            isBare: false,
            isDetached: branch == nil,
            isLocked: false,
            lockReason: nil,
            isPrunable: prunable != nil,
            prunableReason: prunable
        )
    }

    /// Every path is reported as present, so the on-disk check never
    /// interferes with a test about branches and tabs.
    private final class AllPresent: FileManager {
        override func fileExists(atPath path: String) -> Bool { true }
    }

    /// Only the paths handed in exist. Used for the "the folder is gone"
    /// case, which is otherwise indistinguishable from the healthy one.
    private final class OnlyPresent: FileManager {
        let present: Set<String>

        init(_ present: Set<String>) {
            self.present = present
            super.init()
        }

        override func fileExists(atPath path: String) -> Bool { present.contains(path) }
    }

    private func derive(
        _ worktrees: [GitWorktree],
        merged: Set<String> = [],
        tabsByPath: [String: [UUID]] = [:],
        fileManager: FileManager = AllPresent()
    ) -> [WorktreeFinding] {
        WorktreeFindings.derive(
            worktrees: worktrees,
            merged: merged,
            tabsByPath: tabsByPath,
            managedRoot: managedRoot,
            fileManager: fileManager
        )
    }

    // MARK: Nothing to report

    @Test func aRepositoryWithOnlyItsMainCheckoutHasNoFindings() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)

        #expect(derive([main]).isEmpty)
    }

    /// The main checkout is never offered for cleanup, whatever else is true
    /// of it: it can't be removed, and its branch being merged is the normal
    /// state of a repository sitting on `main`.
    @Test func theMainCheckoutIsNeverFlagged() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)

        #expect(derive([main], merged: ["main"]).isEmpty)
    }

    /// Even a main checkout inside the managed root — somebody who pointed
    /// the setting at a folder they already keep clones in — with no tab
    /// open in it.
    @Test func theMainCheckoutInsideTheManagedRootIsNotAnOrphan() {
        let main = worktree("\(managedRoot)/phantom/main", branch: "main", isMain: true)

        #expect(derive([main]).isEmpty)
    }

    // MARK: Orphans

    @Test func aManagedWorktreeWithNoTabsIsAnOrphan() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let idle = worktree("\(managedRoot)/phantom/feat-x")

        #expect(derive([main, idle]) == [.orphan(idle)])
    }

    @Test func aManagedWorktreeWithATabIsNotAnOrphan() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let busy = worktree("\(managedRoot)/phantom/feat-x")

        #expect(derive([main, busy], tabsByPath: [busy.path: [UUID()]]).isEmpty)
    }

    /// A worktree the user made by hand, somewhere of their own choosing, is
    /// not this app's to tidy away. The orphan rule is the one place the
    /// managed root matters, and it is what keeps the pane from proposing to
    /// delete a folder it never created.
    @Test func aWorktreeOutsideTheManagedRootIsNeverAnOrphan() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let elsewhere = worktree("/Users/dev/scratch/phantom-feat-x")

        #expect(derive([main, elsewhere]).isEmpty)
    }

    /// An empty list of tabs means the same as no entry at all — a caller
    /// that removed the last tab without pruning the key must not accidentally
    /// keep the worktree looking busy.
    @Test func anEmptyTabListCountsAsNoTabs() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let idle = worktree("\(managedRoot)/phantom/feat-x")

        #expect(derive([main, idle], tabsByPath: [idle.path: []]) == [.orphan(idle)])
    }

    // MARK: Merged

    @Test func aWorktreeWhoseBranchHasLandedIsMerged() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let landed = worktree("\(managedRoot)/phantom/feat-x", branch: "feat/x")

        #expect(derive([main, landed], merged: ["feat/x"]) == [.merged(landed)])
    }

    /// Suppressing it would leave the branch to rot unmentioned. The open
    /// tabs get their warning in the remove flow, which is where the user
    /// can still say no.
    @Test func aMergedWorktreeWithTabsIsStillReported() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let landed = worktree("\(managedRoot)/phantom/feat-x", branch: "feat/x")

        #expect(derive([main, landed], merged: ["feat/x"], tabsByPath: [landed.path: [UUID()]])
            == [.merged(landed)])
    }

    /// A detached worktree has no branch to have been merged, and no branch
    /// to delete afterwards. Asking the merged set about `nil` would be
    /// asking a question with no subject.
    @Test func aDetachedWorktreeIsNeverMerged() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let detached = worktree("/Users/dev/scratch/inspect", branch: nil)

        #expect(derive([main, detached], merged: ["feat/x"]).isEmpty)
    }

    /// A merged worktree outside the managed root is still reported —
    /// unlike the orphan rule, this one doesn't care who created the folder,
    /// because "your branch is already in main" is worth saying either way.
    @Test func aMergedWorktreeOutsideTheManagedRootIsReported() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let landed = worktree("/Users/dev/scratch/feat-x", branch: "feat/x")

        #expect(derive([main, landed], merged: ["feat/x"]) == [.merged(landed)])
    }

    /// The merged set is taken exactly as given. A branch cut from the base
    /// and never committed to is "merged" as far as `git branch --merged` is
    /// concerned, and excluding it needs the base's tip — which needs git,
    /// which this must not run. `WorktreeCenter` owns that filter; this file
    /// pins that the split stays where it is, because a second copy of the
    /// rule here would be the one that goes stale.
    @Test func theMergedSetIsTrustedWithoutSecondGuessing() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true, head: "aaa111")
        let fresh = worktree("\(managedRoot)/phantom/feat-x", branch: "feat/x", head: "aaa111")

        #expect(derive([main, fresh], merged: ["feat/x"]) == [.merged(fresh)])
    }

    // MARK: Broken

    @Test func aPrunableWorktreeIsBroken() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let gone = worktree(
            "\(managedRoot)/phantom/feat-x",
            prunable: "gitdir file points to non-existent location"
        )

        #expect(derive([main, gone])
            == [.broken(path: gone.path, reason: "gitdir file points to non-existent location")])
    }

    /// Deleted with Finder, or on a volume that isn't mounted. Git still
    /// lists the worktree and hasn't marked it prunable yet, so the folder's
    /// absence is the only signal — and it is a lost state rather than an
    /// error, which is why there is a reason to show instead of a failure.
    @Test func aWorktreeWhoseFolderIsGoneIsBroken() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let gone = worktree("\(managedRoot)/phantom/feat-x")

        let findings = derive([main, gone], fileManager: OnlyPresent([main.path]))

        #expect(findings.count == 1)
        guard case .broken(let path, let reason) = findings[0] else {
            Issue.record("expected a broken finding, got \(findings[0])")
            return
        }
        #expect(path == gone.path)
        #expect(!reason.isEmpty)
    }

    /// A broken worktree whose branch also landed is reported once, as
    /// broken: there is nothing on disk to merge or open, and the removal is
    /// the same either way.
    @Test func brokenBeatsMergedForTheSameWorktree() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let gone = worktree(
            "\(managedRoot)/phantom/feat-x",
            branch: "feat/x",
            prunable: "gitdir file points to non-existent location"
        )

        let findings = derive([main, gone], merged: ["feat/x"])

        #expect(findings.count == 1)
        #expect(findings[0] == .broken(path: gone.path, reason: "gitdir file points to non-existent location"))
    }

    /// Merged is the more useful of the two labels: "its branch is in the
    /// base" is what makes deleting it safe, where "nobody has it open" only
    /// makes it quiet. So a worktree that is both is reported as merged, and
    /// reported once.
    @Test func mergedBeatsOrphanForTheSameWorktree() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let both = worktree("\(managedRoot)/phantom/feat-x", branch: "feat/x")

        #expect(derive([main, both], merged: ["feat/x"]) == [.merged(both)])
    }

    // MARK: Order

    /// Most actionable first, which is also least ambiguous first: a broken
    /// worktree has nothing to lose, a merged one has nothing left to land,
    /// and an orphan is only a guess that the user is done with it.
    @Test func findingsAreOrderedBrokenThenMergedThenOrphan() {
        let main = worktree("/Users/dev/Projects/phantom", branch: "main", isMain: true)
        let orphan = worktree("\(managedRoot)/phantom/feat-orphan", branch: "feat/orphan")
        let landed = worktree("\(managedRoot)/phantom/feat-landed", branch: "feat/landed")
        let gone = worktree("\(managedRoot)/phantom/feat-gone", branch: "feat/gone", prunable: "prunable")

        let findings = derive([main, orphan, landed, gone], merged: ["feat/landed"])

        #expect(findings == [
            .broken(path: gone.path, reason: "prunable"),
            .merged(landed),
            .orphan(orphan),
        ])
    }
}
