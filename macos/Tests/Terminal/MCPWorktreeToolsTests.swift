import Foundation
@testable import Ghostty
import Testing

/// The worktree tools an agent can call, and — mostly — what they refuse.
///
/// The refusals are the point. Everything else here goes through
/// `WorktreeCenter`, which already has its own tests; what is new is a caller
/// that is not a person looking at a pane. A removal deletes a folder, and
/// forced it deletes uncommitted work that exists in no other copy, so the
/// question worth asserting is not "does it work" but "what does it decline to
/// do".
@MainActor
struct MCPWorktreeToolsTests {
    private func tool(_ name: String) -> MCPToolHandler? {
        MCPWorktreeTools.all.first { $0.tool.name == name }
    }

    private func run(
        _ handler: MCPToolHandler,
        _ arguments: [String: JSONValue]
    ) -> MCPToolResult? {
        var result: MCPToolResult?
        handler.run(
            MCPToolContext(
                callerSurface: nil,
                clientName: "test",
                client: ObjectIdentifier(MCPWorktreeTools.self as AnyObject),
                arguments: arguments)
        ) { result = $0 }
        return result
    }

    private func refusal(_ result: MCPToolResult?) -> String? {
        guard case .refused(let message)? = result else { return nil }
        return message
    }

    // MARK: What is offered at all

    @Test func everyWorktreeOperationIsReachable() {
        let names = MCPWorktreeTools.all.map(\.tool.name)

        #expect(names.contains("list_worktrees"))
        #expect(names.contains("add_worktree"))
        #expect(names.contains("remove_worktree"))
        #expect(names.contains("tidy_worktrees"))
    }

    /// Writing worktrees has its own capability. Folded into `configure` it
    /// would mean a reader who allowed a language server's startup setting had
    /// allowed a folder to be deleted; folded into `run` it would mean a grant
    /// about one shell reached the whole repository.
    @Test func writingWorktreesIsItsOwnCapability() {
        #expect(MCPPermission.Capability.allCases.contains(.worktree))
        #expect(MCPPermission.Capability.worktree != .configure)
        #expect(!MCPPermission.Capability.worktree.title.isEmpty)
    }

    // MARK: Refusals that need no repository

    @Test func aToolCalledOutsideARepositoryExplainsItself() throws {
        let listed = try #require(tool("list_worktrees"))
        let message = refusal(run(listed, ["path": .string("/tmp")]))

        #expect(message?.contains("git repository") == true)
    }

    @Test func addRefusesWithoutAPath() throws {
        let add = try #require(tool("add_worktree"))
        let message = refusal(run(add, ["path": .string("/tmp")]))

        #expect(message != nil)
    }

    @Test func tidyRefusesAnActionItDoesNotHave() throws {
        let tidy = try #require(tool("tidy_worktrees"))
        let message = refusal(run(tidy, [
            "path": .string("/tmp"),
            "action": .string("delete-everything"),
        ]))

        /// Names the actions it does have. A refusal that only says "no"
        /// teaches the caller nothing and it guesses again.
        #expect(message != nil)
    }

    // MARK: The path rules

    /// A path git handed out and a path an agent typed can spell the same
    /// folder differently. Comparing the strings would answer "not a worktree
    /// of this repository" for a path `list_worktrees` had just reported.
    @Test func pathsAreComparedAfterResolving() {
        let home = NSHomeDirectory()

        #expect(MCPWorktreeTools.samePath("~/Projects", "\(home)/Projects"))
        #expect(MCPWorktreeTools.samePath("/tmp/a", "/tmp/a"))
        #expect(!MCPWorktreeTools.samePath("/tmp/a", "/tmp/b"))
    }

    @Test func aTrailingSlashIsTheSameFolder() {
        #expect(MCPWorktreeTools.samePath("/tmp/a/", "/tmp/a"))
    }

    // MARK: What a worktree looks like to an agent

    /// Every field it needs to decide, and the removal safety in words rather
    /// than left to be inferred from three booleans.
    @Test func aWorktreeIsDescribedWithWhatDecidesARemoval() throws {
        let worktree = GitWorktree(
            path: "/tmp/wt",
            head: "abc123",
            branch: "feat/x",
            isMain: false,
            isBare: false,
            isDetached: false,
            isLocked: true,
            lockReason: "on a network mount",
            isPrunable: false,
            prunableReason: nil)

        let described = try #require(
            MCPWorktreeTools.describe(worktree, merged: ["feat/x"]).object)

        #expect(described["path"]?.string == "/tmp/wt")
        #expect(described["branch"]?.string == "feat/x")
        #expect(described["is_locked"]?.bool == true)
        #expect(described["lock_reason"]?.string == "on a network mount")
        /// Whether the branch has merged is what makes a removal safe.
        #expect(described["branch_is_merged"]?.bool == true)
    }

    @Test func anUnmergedBranchSaysSo() throws {
        let worktree = GitWorktree(
            path: "/tmp/wt", head: nil, branch: "feat/y",
            isMain: false, isBare: false, isDetached: false,
            isLocked: false, lockReason: nil, isPrunable: false, prunableReason: nil)

        let described = try #require(MCPWorktreeTools.describe(worktree, merged: []).object)

        #expect(described["branch_is_merged"]?.bool == false)
    }

    /// A detached worktree has no branch, and the field says null rather than
    /// an empty string — an agent testing for a branch must not get "".
    @Test func aDetachedWorktreeHasNoBranch() throws {
        let worktree = GitWorktree(
            path: "/tmp/wt", head: "abc", branch: nil,
            isMain: false, isBare: false, isDetached: true,
            isLocked: false, lockReason: nil, isPrunable: false, prunableReason: nil)

        let described = try #require(MCPWorktreeTools.describe(worktree, merged: []).object)

        #expect(described["branch"] == .null)
        #expect(described["branch_is_merged"] == nil)
        #expect(described["is_detached"]?.bool == true)
    }

    // MARK: The descriptions an agent reads before choosing

    /// The one that destroys work has to say so in the text the model sees,
    /// not only in the prompt the human sees afterwards.
    @Test func theRemovalToolWarnsInItsOwnDescription() throws {
        let remove = try #require(tool("remove_worktree"))
        let text = remove.tool.description.lowercased()

        #expect(text.contains("delet"))
        #expect(text.contains("uncommitted"))
        #expect(text.contains("force"))
    }

    /// Housekeeping says it is housekeeping, so an agent tidying a list does
    /// not think it is risking files.
    @Test func tidySaysItTouchesNoFiles() throws {
        let tidy = try #require(tool("tidy_worktrees"))

        #expect(tidy.tool.description.lowercased().contains("none of which touches"))
    }
}
