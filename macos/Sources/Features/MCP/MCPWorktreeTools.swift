import Foundation

/// The worktree pane, reachable by an agent.
///
/// ## Why these and not `run_command`
///
/// An agent can already type `git worktree add` into a terminal, and doing so
/// works — on git. It does not work on the app: the pane keeps a list, a set
/// of merged branches and a resolved base ref per repository, refreshed when
/// *it* runs an operation. A worktree made behind its back is a worktree the
/// screen does not know about, so the reader sees a stale pane and the agent
/// sees a success. These tools go through ``WorktreeCenter``, which is what
/// the pane itself uses, so the two cannot disagree.
///
/// It also means one place decides how each operation is spelled. The reason
/// `add_worktree` uses `worktree add -b` rather than a branch call followed
/// by an add is written down in the centre, and an agent composing the
/// command itself would have to rediscover it — by leaving a branch behind
/// after a failed checkout.
///
/// ## What is gated and what is not
///
/// Reading is free. Everything that writes asks once, under its own
/// capability — see ``MCPPermission/Capability/worktree`` for why it is not
/// folded into `configure` or `run`.
///
/// **A removal asks every time.** The grant covers asking; it does not cover
/// deleting a second folder because the reader once allowed the first. And a
/// forced removal is refused outright unless the caller says `force: true`
/// *and* the prompt is answered again with the loss spelled out, because that
/// is the one operation here that destroys work no copy of exists.
@MainActor
enum MCPWorktreeTools {
    static var all: [MCPToolHandler] {
        [listWorktrees, addWorktree, removeWorktree, tidyWorktrees]
    }

    // MARK: Reading

    static var listWorktrees: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_worktrees",
                description: """
                    List the git worktrees of the repository a terminal is in: their \
                    paths, branches, and whether each is the main checkout, locked, \
                    detached or prunable. Also says which branches have already merged \
                    into the base, which is what makes a worktree safe to remove. Read \
                    only. Call this before add_worktree or remove_worktree — the paths \
                    those take come from here.
                    """,
                schema: MCPSchema.object([
                    "path": MCPSchema.string(
                        "Any path inside the repository. Defaults to the calling "
                        + "terminal's working directory."),
                ], required: []))
        ) { context, answer in
            guard let root = resolveRoot(context) else {
                return answer(.refused(noRepository))
            }

            WorktreeCenter.shared.requestList(commonRoot: root, force: true)
            WorktreeCenter.shared.requestMerged(commonRoot: root, force: true)

            /// A `Task`, because a handler is synchronous and the centre
            /// loads off the main actor. Answering the cache immediately
            /// would hand back the previous repository's list on the first
            /// call for a new one, so this waits for the load it just asked
            /// for — bounded, see `settle`.
            Task { @MainActor in
                await settle(root: root)

                let listed = WorktreeCenter.shared.list(forRoot: root)
                guard !listed.isEmpty else {
                    return answer(.refused(
                        "Could not read the worktrees of \(root). The repository may "
                        + "have no git directory this app can reach, or git did not "
                        + "answer."))
                }

                let merged = WorktreeCenter.shared.merged(forRoot: root)
                let base = WorktreeCenter.shared.baseRef(forRoot: root)

                answer(.json(.object([
                    "repository": .string(root),
                    "base": base.map { .string($0) } ?? .null,
                    "worktrees": .array(listed.map { describe($0, merged: merged) }),
                ])))
            }
        }
    }

    // MARK: Creating

    static var addWorktree: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "add_worktree",
                description: """
                    Create a git worktree — a second working directory of the same \
                    repository, on its own branch, so work can proceed without \
                    disturbing the current checkout. Pass `branch` for a branch that \
                    exists, or `new_branch` (with an optional `from`) to create one. \
                    Asks the reader once per session.
                    """,
                schema: MCPSchema.object([
                    "worktree_path": MCPSchema.string(
                        "Where to create the folder. Absolute, and it must not exist."),
                    "branch": MCPSchema.string(
                        "An existing branch to check out there."),
                    "new_branch": MCPSchema.string(
                        "A branch to create for it. Use instead of `branch`."),
                    "from": MCPSchema.string(
                        "What `new_branch` starts from. Defaults to the repository's "
                        + "base branch as list_worktrees reports it."),
                    "path": MCPSchema.string(
                        "Any path inside the repository. Defaults to the calling "
                        + "terminal's working directory."),
                ], required: ["worktree_path"]))
        ) { context, answer in
            guard let root = resolveRoot(context) else {
                return answer(.refused(noRepository))
            }
            guard let target = context.string("worktree_path"), !target.isEmpty else {
                return answer(.refused("add_worktree needs a `worktree_path`."))
            }
            guard !FileManager.default.fileExists(atPath: target) else {
                return answer(.refused(
                    "\(target) already exists. `git worktree add` refuses an existing "
                    + "path, and this does too rather than writing into it."))
            }

            let existing = context.string("branch")
            let created = context.string("new_branch")
            guard existing == nil || created == nil else {
                return answer(.refused(
                    "Pass `branch` or `new_branch`, not both — they are two different "
                    + "requests and git takes one of them."))
            }
            guard existing != nil || created != nil else {
                return answer(.refused(
                    "add_worktree needs `branch` for an existing branch or "
                    + "`new_branch` to create one."))
            }

            let detail = created.map { name in
                "Create \(target) on a new branch \(name)"
                    + (context.string("from").map { ", from \($0)" } ?? "")
            } ?? "Create \(target) on \(existing ?? "")"

            ask(context, detail: detail) { granted in
                guard granted else { return answer(.refused(refusal)) }

                let done: @MainActor (Bool) -> Void = { ok in
                    answer(outcome(ok, did: "Created \(target)", root: root))
                }

                if let created {
                    let base = context.string("from")
                        ?? WorktreeCenter.shared.baseRef(forRoot: root)
                        ?? "HEAD"
                    WorktreeCenter.shared.add(
                        path: target, newBranch: created, from: base,
                        commonRoot: root, completion: done)
                } else if let existing {
                    WorktreeCenter.shared.add(
                        path: target, branch: existing, commonRoot: root, completion: done)
                }
            }
        }
    }

    // MARK: Removing

    static var removeWorktree: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "remove_worktree",
                description: """
                    Remove a git worktree, deleting its folder. Optionally delete its \
                    branch with it. Git refuses a worktree holding uncommitted changes \
                    unless `force` is true, and forcing destroys that work — no copy of \
                    it exists anywhere. Asks the reader every time, forced or not. \
                    Never the main checkout.
                    """,
                schema: MCPSchema.object([
                    "worktree_path": MCPSchema.string(
                        "The worktree's path, as list_worktrees reported it."),
                    "delete_branch": MCPSchema.boolean(
                        "Also delete the branch it was on. Refused by git if the "
                        + "branch has not merged."),
                    "force": MCPSchema.boolean(
                        "Remove even though it holds uncommitted changes, destroying "
                        + "them. Defaults to false."),
                    "path": MCPSchema.string(
                        "Any path inside the repository. Defaults to the calling "
                        + "terminal's working directory."),
                ], required: ["worktree_path"]))
        ) { context, answer in
            guard let root = resolveRoot(context) else {
                return answer(.refused(noRepository))
            }
            guard let target = context.string("worktree_path") else {
                return answer(.refused("remove_worktree needs a `worktree_path`."))
            }

            WorktreeCenter.shared.requestList(commonRoot: root, force: true)

            Task { @MainActor in
            await settle(root: root)

            let listed = WorktreeCenter.shared.list(forRoot: root)
            guard let found = listed.first(where: { samePath($0.path, target) }) else {
                return answer(.refused(
                    "\(target) is not a worktree of \(root). Call list_worktrees for "
                    + "the paths it has."))
            }

            /// The main checkout is the repository. Removing it is not an
            /// operation this offers at any permission level.
            guard !found.isMain else {
                return answer(.refused(
                    "\(target) is the main checkout, not a worktree. Removing it would "
                    + "remove the repository's own working directory."))
            }
            guard !found.isLocked else {
                return answer(.refused(
                    "\(target) is locked"
                    + (found.lockReason.map { " (\($0))" } ?? "")
                    + ". A lock protects a worktree on removable media or a network "
                    + "mount from being pruned as if its folder had been deleted. Lift "
                    + "it in the Worktrees pane if that is what you mean."))
            }

            let force = context.bool("force") ?? false
            let alsoBranch = context.bool("delete_branch") ?? false

            var detail = "Remove \(target)"
            if alsoBranch, let branch = found.branch { detail += " and delete \(branch)" }
            if force {
                detail += "\n\nFORCED: this deletes uncommitted work in that folder. "
                    + "Nothing in this app can bring it back."
            }

            ask(context, detail: detail) { granted in
                guard granted else { return answer(.refused(refusal)) }

                let done: @MainActor (Bool) -> Void = { ok in
                    answer(outcome(ok, did: "Removed \(target)", root: root))
                }

                if alsoBranch, let branch = found.branch, !force {
                    WorktreeCenter.shared.removeAndDeleteBranch(
                        path: target, branch: branch, commonRoot: root, completion: done)
                } else {
                    WorktreeCenter.shared.remove(
                        path: target, force: force, commonRoot: root, completion: done)
                }
            }
            }
        }
    }

    // MARK: Keeping the list honest

    static var tidyWorktrees: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "tidy_worktrees",
                description: """
                    Housekeeping on the worktree list, none of which touches your \
                    files. `prune` drops git's records of worktrees whose folders are \
                    already gone. `repair` reconnects one whose folder was moved behind \
                    git's back. `move` relocates one, keeping git's pointers in step — \
                    use it instead of moving the folder yourself. Asks the reader once \
                    per session.
                    """,
                schema: MCPSchema.object([
                    "action": MCPSchema.string("One of `prune`, `repair`, `move`."),
                    "worktree_path": MCPSchema.string(
                        "The worktree to act on. Required by `repair` and `move`."),
                    "new_path": MCPSchema.string("Where `move` puts it."),
                    "path": MCPSchema.string(
                        "Any path inside the repository. Defaults to the calling "
                        + "terminal's working directory."),
                ], required: ["action"]))
        ) { context, answer in
            guard let root = resolveRoot(context) else {
                return answer(.refused(noRepository))
            }
            guard let action = context.string("action") else {
                return answer(.refused("tidy_worktrees needs an `action`."))
            }

            let target = context.string("worktree_path")
            let moved = context.string("new_path")

            let detail: String
            switch action {
            case "prune": detail = "Prune worktree records with no folder, in \(root)"
            case "repair":
                guard target != nil else {
                    return answer(.refused("`repair` needs a `worktree_path`."))
                }
                detail = "Repair \(target ?? "")"
            case "move":
                guard let target, let moved else {
                    return answer(.refused("`move` needs `worktree_path` and `new_path`."))
                }
                guard !FileManager.default.fileExists(atPath: moved) else {
                    return answer(.refused("\(moved) already exists."))
                }
                detail = "Move \(target) to \(moved)"
            default:
                return answer(.refused(
                    "`action` is one of `prune`, `repair`, `move` — not \"\(action)\"."))
            }

            ask(context, detail: detail) { granted in
                guard granted else { return answer(.refused(refusal)) }

                let done: @MainActor (Bool) -> Void = { ok in
                    answer(outcome(ok, did: detail, root: root))
                }

                switch action {
                case "prune":
                    WorktreeCenter.shared.prune(commonRoot: root, completion: done)
                case "repair":
                    WorktreeCenter.shared.repair(
                        path: target ?? "", commonRoot: root, completion: done)
                default:
                    WorktreeCenter.shared.move(
                        path: target ?? "", to: moved ?? "",
                        commonRoot: root, completion: done)
                }
            }
        }
    }

    // MARK: Shared

    static let noRepository = """
        No git repository here. Pass `path` pointing inside one, or call this from a \
        terminal whose working directory is in a repository.
        """

    static let refusal = "The reader declined. Nothing was changed."

    /// The repository every worktree of a family shares.
    ///
    /// `GitCommonDir.resolve` rather than the path as given, because a
    /// worktree's own directory is not where git keeps the family's records —
    /// so an agent calling this from inside one worktree still gets the whole
    /// list rather than a repository of one.
    static func resolveRoot(_ context: MCPToolContext) -> String? {
        let candidate = context.string("path")
            ?? context.callerSurface.flatMap { MCPTerminalTools.tab(for: $0)?.pwd }
        guard let candidate, !candidate.isEmpty else { return nil }
        return GitCommonDir.resolve(from: candidate)
    }

    /// Whether two paths name the same worktree.
    ///
    /// Resolved before comparing: an agent passing `~/Projects/x` and git
    /// reporting `/Users/me/Projects/x` mean the same folder, and a string
    /// comparison would answer "not a worktree of this repository" for a path
    /// list_worktrees had just handed out.
    static func samePath(_ left: String, _ right: String) -> Bool {
        guard left != right else { return true }
        let resolve: (String) -> String = {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        return resolve(left) == resolve(right)
    }

    /// One worktree, in the shape an agent can act on: every field it needs to
    /// decide, and the removal safety in words rather than left to be inferred
    /// from three booleans.
    static func describe(_ worktree: GitWorktree, merged: Set<String>) -> JSONValue {
        var fields: [String: JSONValue] = [
            "path": .string(worktree.path),
            "branch": worktree.branch.map { .string($0) } ?? .null,
            "head": worktree.head.map { .string($0) } ?? .null,
            "is_main": .bool(worktree.isMain),
            "is_bare": .bool(worktree.isBare),
            "is_detached": .bool(worktree.isDetached),
            "is_locked": .bool(worktree.isLocked),
            "is_prunable": .bool(worktree.isPrunable),
        ]
        if let reason = worktree.lockReason { fields["lock_reason"] = .string(reason) }
        if let reason = worktree.prunableReason { fields["prunable_reason"] = .string(reason) }
        if let branch = worktree.branch {
            fields["branch_is_merged"] = .bool(merged.contains(branch))
        }
        return .object(fields)
    }

    /// Asks under the worktree capability, naming the tab the caller is in so
    /// the prompt says where the request came from.
    static func ask(
        _ context: MCPToolContext,
        detail: String,
        then decided: @escaping @MainActor (Bool) -> Void
    ) {
        let tab = context.callerSurface.flatMap { MCPTerminalTools.tab(for: $0) }
        MCPPermissionStore.shared.decide(
            MCPPermission.Request(
                capability: .worktree,
                surface: context.callerSurface,
                group: tab.flatMap { found in
                    context.callerSurface.flatMap {
                        SidebarGroupStore.shared.resolveGroup(surfaceId: $0, pwd: found.pwd)?
                            .id.uuidString
                    }
                }),
            client: context.client,
            clientName: context.clientName,
            tabTitle: tab.map { MCPTerminalTools.displayTitle($0) },
            detail: detail,
            then: decided)
    }

    /// What an operation answers with.
    ///
    /// A failure hands back the centre's own message rather than a generic
    /// one: git's refusals here are the useful part — "contains modified or
    /// untracked files", "not a valid ref" — and an agent that gets "failed"
    /// retries the same call.
    static func outcome(_ ok: Bool, did: String, root: String) -> MCPToolResult {
        guard ok else {
            let failure = WorktreeCenter.shared.lastError?.failure
            let message = failure?.summary ?? failure?.title ?? "git gave no reason."
            return .refused("\(did) failed. \(message)")
        }
        return .text("\(did). Call list_worktrees for the repository's state now.")
    }

    /// Waits for the load the caller just asked for, bounded.
    ///
    /// The bound is what makes this safe to call from a tool: a repository git
    /// cannot answer about would otherwise hold the connection open, and a
    /// tool that never returns is worse to an agent than one that says it
    /// could not tell.
    static func settle(root: String, attempts: Int = 40) async {
        for _ in 0..<attempts {
            if WorktreeCenter.shared.busy[root] == nil,
               WorktreeCenter.shared.hasLoaded(root) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
