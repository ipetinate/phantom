import AppKit
@testable import Ghostty
import Testing

/// What a git panel row offers, and to which files.
///
/// Written after the menu was reported missing an item that was there: "Add to
/// .gitignore" appeared only on untracked files, and it was the *only* thing
/// besides Copy Path that ever appeared at all — so right-clicking a modified
/// file produced a one-item menu that read as a broken feature.
///
/// Both halves of that turned out to be wrong. The menu is now everything a row
/// can do, and the ignore item is offered on tracked files too, matching the
/// `when` clauses VS Code's git extension declares. The rules below are the ones
/// that decide the menu, asserted here so the next person can tell which
/// absences are deliberate — the deletion's missing file items, the conflict's
/// missing discard — from an item that simply has not been wired up.
struct GitRowActionTests {
    private func change(
        path: String = "src/main.swift",
        index: Character = ".",
        worktree: Character = "M",
        isUntracked: Bool = false,
        isUnmerged: Bool = false
    ) -> GitFileChange {
        GitFileChange(
            path: path,
            originalPath: nil,
            index: index,
            worktree: worktree,
            isUntracked: isUntracked,
            isUnmerged: isUnmerged
        )
    }

    private func actions(
        for change: GitFileChange,
        staged: Bool = false,
        canDiscard: Bool = true,
        canIgnore: Bool = true
    ) -> [GitRowAction] {
        GitRowAction.groups(
            for: change,
            staged: staged,
            canDiscard: canDiscard,
            canIgnore: canIgnore
        ).flatMap { $0 }
    }

    /// The report this came from, stated as a test: a tracked file's menu was
    /// Copy Path and nothing else.
    @Test func aModifiedFileOffersEverythingItCanDo() {
        let items = actions(for: change())

        #expect(items == [
            .openDiff,
            .openFile,
            .stage,
            .discardChanges,
            .addToGitignore,
            .revealInFinder,
            .copyPath,
            .copyRelativePath,
        ])
    }

    /// A tracked file is offered the ignore rule too, which is where this
    /// started: it was gated on being untracked, on the grounds that a rule
    /// against a tracked path has no visible effect. It still has none — git
    /// carries on reporting the file and nothing untracks it — but VS Code
    /// exposes `git.ignore` for its `workingTree` group as well as `untracked`,
    /// and writing the rule down is what was asked for either way.
    @Test func bothTrackedAndUntrackedFilesAreOfferedGitignore() {
        #expect(actions(for: change()).contains(.addToGitignore))
        #expect(actions(for: change(worktree: "?", isUntracked: true)).contains(.addToGitignore))
    }

    /// The two groups VS Code leaves it out of, for the same reason it does:
    /// `index` and `merge` get no ignore item. A staged row is the index; a
    /// host signals a conflict by wiring neither callback.
    @Test func aStagedOrConflictedRowIsNotOfferedGitignore() {
        #expect(!actions(for: change(index: "M", worktree: "."), staged: true)
            .contains(.addToGitignore))

        #expect(!actions(
            for: change(index: "U", worktree: "U", isUnmerged: true),
            canDiscard: false,
            canIgnore: false
        ).contains(.addToGitignore))
    }

    /// An untracked file has no change to throw away — discarding it removes
    /// the file — so the item says that before the confirmation does.
    @Test func anUntrackedFileIsOfferedDeletionRatherThanDiscarding() {
        let items = actions(for: change(worktree: "?", isUntracked: true))

        #expect(items.contains(.deleteUntrackedFile))
        #expect(!items.contains(.discardChanges))
    }

    /// A deletion keeps the row, keeps the diff — that is where you go to see
    /// what left — and loses only the items that need a file to exist.
    @Test func aDeletedFileKeepsItsDiffAndLosesTheFileItems() {
        for deletion in [change(worktree: "D"), change(index: "D", worktree: ".")] {
            let items = actions(for: deletion)

            #expect(items.contains(.openDiff))
            #expect(items.contains(.discardChanges), "the discard is how it comes back")
            #expect(!items.contains(.openFile))
            #expect(!items.contains(.revealInFinder))
            #expect(items.contains(.copyRelativePath), "the path is still worth copying")
        }
    }

    /// A path deleted in the index and written again in the working tree has a
    /// file, so the worktree column is the one that answers.
    @Test func aDeletionPutBackCountsAsPresent() {
        #expect(change(index: "D", worktree: "M").isPresentOnDisk)
        #expect(change(worktree: "?", isUntracked: true).isPresentOnDisk)
    }

    /// A conflicted file's host wires no discard, because "discard the change"
    /// has no single meaning with two sides in play. The rest of the menu is
    /// unaffected, which is the point of asking rather than assuming.
    @Test func aConflictedFileLosesOnlyTheDiscard() {
        let items = actions(
            for: change(index: "U", worktree: "U", isUnmerged: true),
            canDiscard: false,
            canIgnore: false
        )

        #expect(!items.contains(.discardChanges))
        #expect(!items.contains(.deleteUntrackedFile))
        #expect(items.contains(.openDiff))
        #expect(items.contains(.stage), "staging is how a resolution is recorded")
    }

    @Test func aStagedRowOffersToUnstage() {
        #expect(actions(for: change(index: "M", worktree: "."), staged: true).contains(.unstage))
        #expect(!actions(for: change(index: "M", worktree: "."), staged: true).contains(.stage))
    }

    /// Groups exist to place separators, so an empty one must not survive to
    /// become a rule against nothing.
    @Test func noGroupIsEverEmpty() {
        for staged in [true, false] {
            for canDiscard in [true, false] {
                for canIgnore in [true, false] {
                    for file in [change(), change(worktree: "?", isUntracked: true), change(worktree: "D")] {
                        let groups = GitRowAction.groups(
                            for: file,
                            staged: staged,
                            canDiscard: canDiscard,
                            canIgnore: canIgnore
                        )
                        #expect(groups.allSatisfy { !$0.isEmpty })
                    }
                }
            }
        }
    }

    /// Every item has to say something in a menu, and the destructive pair has
    /// to warn that it will ask.
    @Test func everyActionIsNamedAndTheDangerousOnesAreMarked() {
        for action in GitRowAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(action.isDestructive == action.title.hasSuffix("…"))
        }
    }

    /// An icon this build cannot draw is a menu item with a hole where its
    /// glyph should be, so the names are asserted rather than trusted — the
    /// `FileExplorerTests` rule, for the menu that sits under that one.
    @Test func everyIconResolves() {
        for action in GitRowAction.allCases {
            let image = NSImage(systemSymbolName: action.icon, accessibilityDescription: nil)
            #expect(image != nil, "\(action.icon) is not a symbol this build has")
        }
    }
}
