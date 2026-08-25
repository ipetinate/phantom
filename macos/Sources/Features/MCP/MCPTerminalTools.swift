import AppKit
import Foundation

/// The terminals, as an agent sitting in one of them can see and use them.
///
/// Five tools, and the line between them is consent rather than convenience.
/// `list_terminals` and `focus_terminal` describe and rearrange the app's own
/// structure; `read_output` and `run_command` reach into a terminal's
/// contents, and neither runs without the reader having granted it. See
/// `listTerminals` and `createTerminal` for the two places that decision was
/// made deliberately rather than by omission.
///
/// The ids handed out are surface UUIDs, which is what `MCPToolContext.surface`
/// parses back — so a tab named in `list_terminals` is a tab `read_output`
/// accepts, with no second identifier to keep in step.
@MainActor
enum MCPTerminalTools {
    static var all: [MCPToolHandler] {
        [listTerminals, readOutput, createTerminal, runCommand, focusTerminal, updateTerminal]
    }

    // MARK: Appearance

    /// Renames a tab, or changes the icon and colour the reader marked it
    /// with.
    ///
    /// **No permission, deliberately**, and the reasoning is the editor's
    /// rather than the shell's: nothing is read and nothing is typed. What
    /// changes is a label in the reader's own sidebar — visible the moment it
    /// happens, undone with the tab's own menu, and carrying none of their
    /// output anywhere.
    ///
    /// An empty string clears, rather than being refused. Removing a mark is
    /// as much a thing to ask for as setting one — it is what the reader asked
    /// for the first time this tool did not exist — and "" is the only way to
    /// say it in a schema whose fields are all optional.
    private static var updateTerminal: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "update_terminal",
                description: """
                    Change how a terminal is labelled in the sidebar: its name, its icon, \
                    or the colour marking it. Only what you pass changes. Pass an empty \
                    string to remove a name or an icon, and “none” for the colour to \
                    remove that. Use it to mark the terminals of one piece of work so the \
                    reader can tell them apart at a glance, or to tidy a mark they asked \
                    you to remove. Nothing is typed into the terminal and nothing it has \
                    printed is read.
                    """,
                schema: MCPSchema.object(
                    [
                        "terminal": MCPSchema.string(
                            "The terminal's id, as list_terminals hands it out."),
                        "name": MCPSchema.string(
                            "What the row is called. An empty string goes back to the "
                            + "title the shell sets."),
                        "icon": MCPSchema.string(
                            "An SF Symbol name, a single emoji, or “agent:” and an "
                            + "agent's name. An empty string removes the icon."),
                        "color": MCPSchema.enumeration(
                            "A colour from list_theme_colors. “none” removes it.",
                            MCPColors.names),
                    ],
                    required: ["terminal"])
            )
        ) { context, answer in
            guard let id = context.surface("terminal") else {
                return answer(.refused(MCPTerminalRefusal.missingTerminal("update_terminal")))
            }

            guard let tab = snapshots().first(where: { $0.id == id }) else {
                return answer(.refused(MCPTerminalRefusal.noSuchTerminal(id)))
            }

            let store = SidebarGroupStore.shared
            var override = store.tabOverrides[id] ?? SidebarGroupStore.TabOverride()

            if let name = context.string("name") {
                override.name = name.isEmpty ? nil : name
            }

            if let icon = context.string("icon") {
                if icon.isEmpty {
                    override.icon = nil
                } else if let refusal = MCPGroupTools.iconRefusal(icon) {
                    return answer(.refused(refusal))
                } else {
                    override.icon = icon
                }
            }

            if let asked = context.string("color") {
                guard let colour = MCPColors.named(asked) else {
                    return answer(.refused(MCPColors.refusal(asked)))
                }
                override.color = colour == .none ? nil : colour

                /// A hex colour wins over a named one — see `TabOverride` —
                /// so a colour asked for by name has to clear the hex, or the
                /// reader's swatch would not change and nothing would say why.
                override.colorHex = nil
            }

            store.setTabOverride(surfaceId: id, override)

            answer(.json(.object([
                "terminal": .string(id.uuidString),
                "name": override.name.map { .string($0) } ?? .null,
                "icon": override.icon.map { .string($0) } ?? .null,
                "color": .string((override.color ?? .none).localizedName.lowercased()),
                "title": .string(tab.title),
            ])))
        }
    }

    // MARK: Reading

    /// Every terminal, with enough about each to choose one.
    ///
    /// **No permission, deliberately.** What this answers with is the app's
    /// own structure — which tabs exist, what they are called, where they sit,
    /// what process each has in the foreground — and none of it is anyone's
    /// output. An agent that had to ask before it could see the list would
    /// have to ask about a terminal it cannot yet name, which makes the
    /// permission sheet unanswerable: the reader would be shown a UUID.
    /// Consent is asked at the step that reads a scrollback or types a
    /// command, where there is a terminal to name and a sentence to read.
    static var listTerminals: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_terminals",
                description: """
                    List every terminal open in Phantom: its id, title, working \
                    directory, foreground process, whether it is idle, any dev \
                    server port detected in it, its sidebar group, the git \
                    worktree it sits in, and the coding agent running in it with \
                    that agent's state. Call this first — every other terminal \
                    tool takes an id from here. Call it again before acting on a \
                    terminal you listed a while ago: titles, directories and \
                    processes change while you think.
                    """,
                schema: MCPSchema.object([:])),
            run: { _, answer in
                let terminals = snapshots()
                answer(.json(.object([
                    "terminals": .array(terminals.map(\.json)),
                    "count": .number(Double(terminals.count)),
                ])))
            })
    }

    /// The tail of a terminal's scrollback.
    ///
    /// Gated on `.read` every single time. This is the most sensitive thing
    /// the app holds — an API key echoed by a failing command, a token in a
    /// URL, the output of something pointed at production — which is why the
    /// grant is asked for the *target* tab rather than the caller's own, and
    /// why nothing here caches a scrollback the reader later revokes access
    /// to.
    static var readOutput: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "read_output",
                description: """
                    Read the last lines of what a terminal has printed, by the id \
                    `list_terminals` gave it. Use it to see how a build, a test run \
                    or another agent's turn is going, and to see what a terminal is \
                    waiting on before you decide to type into it. The reader must \
                    grant permission the first time you ask for a terminal, so \
                    expect a refusal you can act on rather than an empty answer.
                    """,
                schema: MCPSchema.object([
                    "terminal": MCPSchema.string(
                        "The terminal's id, as `list_terminals` reported it."),
                    "lines": MCPSchema.integer(
                        "How many trailing lines to return. Defaults to 200, capped at 5000."),
                ], required: ["terminal"])),
            run: { context, answer in
                guard let id = context.surface("terminal") else {
                    return answer(.refused(MCPTerminalRefusal.missingTerminal("read_output")))
                }
                guard let tab = tab(for: id) else {
                    return answer(.refused(MCPTerminalRefusal.noSuchTerminal(id)))
                }

                let title = displayTitle(tab)
                allow(.read, for: tab, id: id, context: context) { granted in
                    guard granted else {
                        return answer(.refused(MCPTerminalRefusal.notAllowedToRead(title)))
                    }
                    guard let surface = AgentLauncher.surface(for: tab) else {
                        return answer(.refused(MCPTerminalRefusal.noSuchTerminal(id)))
                    }

                    /// The 500ms-cached whole-screen read the app already keeps
                    /// for its App Intents. `ghostty_surface_read_text` is
                    /// documented as expensive and asks callers to cache and
                    /// throttle; a second binding here would be a second place
                    /// to forget that.
                    let whole = surface.cachedScreenContents.get()
                    let wanted = clampedLines(context.int("lines"))
                    let text = tail(of: whole, lines: wanted)

                    /// Measured against the same trimming `tail` applies, not
                    /// against the raw buffer: a scrollback shorter than the
                    /// number asked for still loses its trailing newline, and
                    /// comparing the two lengths reported every read as
                    /// truncated.
                    let complete = tail(of: whole, lines: .max)

                    answer(.json(.object([
                        "terminal": .string(id.uuidString),
                        "title": .string(title),
                        "lines": .number(Double(lineCount(text))),
                        "truncated": .bool(text.count < complete.count),
                        "text": .string(text),
                    ])))
                }
            })
    }

    // MARK: Terminals

    /// A new tab, in a directory or a worktree, optionally in a group and
    /// optionally with an agent already starting in it.
    ///
    /// **No permission, deliberately** — and the spec says why: creating is
    /// reversible by looking, where closing kills a shell. Nothing existing is
    /// read and nothing existing is typed into.
    ///
    /// The boundary that keeps this from being an ungated `run_command`: the
    /// only text ever sent is `CodingAgent.launchCommand`, one of four fixed
    /// words. There is no argument here a caller can put a command in.
    static var createTerminal: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "create_terminal",
                description: """
                    Open a new terminal tab in Phantom, in a directory or a git \
                    worktree, optionally inside a sidebar group and optionally \
                    with a coding agent already starting in it. Use it to give a \
                    task its own terminal instead of typing into one somebody is \
                    watching. Answers with the new terminal's id, which \
                    `read_output` and `run_command` take.
                    """,
                schema: MCPSchema.object([
                    "working_directory": MCPSchema.string(
                        "Absolute path to start in. Defaults to the group's project root, "
                        + "or to Phantom's configured home directory."),
                    "worktree": MCPSchema.string(
                        "A git worktree to start in: either its path or its branch name, as "
                        + "`list_terminals` reports them. Wins over `working_directory`."),
                    "group": MCPSchema.string(
                        "A sidebar group to put the tab in, by name or by id, as "
                        + "`list_terminals` reports them."),
                    "agent": MCPSchema.enumeration(
                        "A coding agent to start in the new terminal.",
                        CodingAgent.allCases.map(\.rawValue)),
                ])),
            run: { context, answer in
                guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else {
                    return answer(.refused(MCPTerminalRefusal.notRunning))
                }

                if let named = context.string("agent"), CodingAgent(rawValue: named) == nil {
                    return answer(.refused(MCPTerminalRefusal.noSuchAgent(named)))
                }
                let agent = context.string("agent").flatMap(CodingAgent.init(rawValue:))

                var group: SidebarGroup?
                if let named = context.string("group") {
                    guard let found = self.group(named: named) else {
                        return answer(.refused(MCPTerminalRefusal.noSuchGroup(named)))
                    }
                    group = found
                }

                var worktree: String?
                if let named = context.string("worktree") {
                    guard let path = worktreePath(named: named, among: knownWorktrees()) else {
                        return answer(.refused(MCPTerminalRefusal.noSuchWorktree(named)))
                    }
                    worktree = path
                }

                let directory = startDirectory(
                    requested: context.string("working_directory"),
                    worktree: worktree,
                    group: group,
                    fallback: TerminalController.sidebarDefaultHomeDirectory)

                var baseConfig = Ghostty.SurfaceConfiguration()
                baseConfig.workingDirectory = directory

                guard let controller = TerminalController.newTab(
                    ghostty, from: NSApp.keyWindow, withBaseConfig: baseConfig),
                      let surface = controller.focusedSurface
                        ?? controller.surfaceTree.root?.leftmostLeaf()
                else { return answer(.refused(MCPTerminalRefusal.couldNotCreate)) }

                /// Recorded even when no group was asked for, for the reason
                /// `TerminalController.newSidebarTab` gives: leaving the
                /// ungrouped case unrecorded lets any project group whose root
                /// contains this directory adopt the tab a moment later.
                SidebarGroupStore.shared.assign(surfaceId: surface.id, to: group?.id)
                if let agent { AgentLauncher.start(agent, in: surface) }
                controller.sidebarTabManager?.scheduleRefresh()

                answer(.json(.object([
                    "terminal": .string(surface.id.uuidString),
                    "working_directory": .string(directory),
                    "group": group.map { .string($0.name) } ?? .null,
                    "agent": agent.map { .string($0.rawValue) } ?? .null,
                ])))
            })
    }

    /// Types a command into a terminal that already exists.
    ///
    /// Two gates, and both are required. The reader must have granted `.run`
    /// for this terminal, *and* the terminal must be sitting at a shell
    /// prompt. The second is not a weaker form of the first: a granted
    /// terminal running a test suite would swallow the command into whatever
    /// owns the keyboard, which is the exact failure
    /// `TerminalIdleCheck.isIdle` was written for — and it counts an
    /// unrecognised foreground process as busy, which errs on the safe side.
    static var runCommand: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "run_command",
                description: """
                    Type a command into an existing terminal and press return. The \
                    terminal must be idle — sitting at a shell prompt with nothing \
                    running on top of it — and the reader must have granted you \
                    permission to run commands in it. A busy terminal is refused, \
                    and the refusal names what is running, so wait for that to \
                    finish rather than retrying. This answers as soon as the \
                    command is typed; read what it printed with `read_output`.
                    """,
                schema: MCPSchema.object([
                    "terminal": MCPSchema.string(
                        "The terminal's id, as `list_terminals` reported it."),
                    "command": MCPSchema.string(
                        "One command line to type. No newlines: this types one command."),
                ], required: ["terminal", "command"])),
            run: { context, answer in
                guard let id = context.surface("terminal") else {
                    return answer(.refused(MCPTerminalRefusal.missingTerminal("run_command")))
                }
                guard let command = context.string("command"), !command.isEmpty else {
                    return answer(.refused(MCPTerminalRefusal.missingCommand))
                }

                /// Refused rather than escaped. `ClaudeSession.run` presses
                /// return itself, so an embedded newline would run several
                /// commands off one grant — and the reader approved a sheet
                /// naming a terminal, not a script.
                guard !command.contains(where: \.isNewline) else {
                    return answer(.refused(MCPTerminalRefusal.multiLineCommand))
                }

                guard let tab = tab(for: id) else {
                    return answer(.refused(MCPTerminalRefusal.noSuchTerminal(id)))
                }
                let title = displayTitle(tab)

                allow(.run, for: tab, id: id, context: context) { granted in
                    guard granted else {
                        return answer(.refused(MCPTerminalRefusal.notAllowedToRun(title)))
                    }

                    /// Asked after the grant and not before, so the answer is
                    /// about the terminal as it is now: the sheet takes as long
                    /// as the reader takes, and a terminal idle when the
                    /// question went up may be running something by the time it
                    /// comes down.
                    if let busy = snapshot(tab).refusalIfBusy {
                        return answer(.refused(busy))
                    }
                    guard let surface = AgentLauncher.surface(for: tab) else {
                        return answer(.refused(MCPTerminalRefusal.noSuchTerminal(id)))
                    }

                    /// The same helper the sidebar types with, which waits for
                    /// the shell to hold the foreground before sending. Typing
                    /// into a shell that has not finished starting drops the
                    /// command silently.
                    ClaudeSession.run(command, in: surface)

                    answer(.json(.object([
                        "terminal": .string(id.uuidString),
                        "title": .string(title),
                        "command": .string(command),
                        "note": .string(
                            "Typed and submitted. Call read_output on this terminal to see "
                            + "what it printed."),
                    ])))
                }
            })
    }

    /// Brings a tab to the front.
    ///
    /// **No permission, deliberately.** Nothing is read and nothing is typed;
    /// the reader is looking straight at the result, which is the cheapest
    /// consent there is.
    static var focusTerminal: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "focus_terminal",
                description: """
                    Bring a terminal to the front of its window, by the id \
                    `list_terminals` gave it. Use it to put in front of the reader \
                    the terminal you want them to look at — one waiting on input, \
                    or one you just created for them.
                    """,
                schema: MCPSchema.object([
                    "terminal": MCPSchema.string(
                        "The terminal's id, as `list_terminals` reported it."),
                ], required: ["terminal"])),
            run: { context, answer in
                guard let id = context.surface("terminal") else {
                    return answer(.refused(MCPTerminalRefusal.missingTerminal("focus_terminal")))
                }
                guard let tab = tab(for: id), let window = tab.window else {
                    return answer(.refused(MCPTerminalRefusal.noSuchTerminal(id)))
                }

                let controller = window.windowController as? TerminalController
                controller?.sidebarTabManager?.select(tab)

                answer(.json(.object([
                    "terminal": .string(id.uuidString),
                    "title": .string(displayTitle(tab)),
                ])))
            })
    }

    // MARK: Asking

    /// Puts one capability in front of `MCPPermissionStore`, asked about the
    /// *target* tab rather than the caller's own.
    ///
    /// The group travels as the group id rather than the name, because a
    /// "sempre" grant outlives the session that made it: anchored on a name, a
    /// renamed group would silently drop a grant, and a group renamed onto an
    /// old name would silently inherit one.
    /// The one consent path the tools share.
    ///
    /// Not private because the diagnostic tools gate on the same grant for
    /// the same reason, and two spellings of "ask the reader for read" would
    /// eventually differ in which tab they name — which is the one detail the
    /// reader uses to decide.
    static func allow(
        _ capability: MCPPermission.Capability,
        for tab: SidebarTabModel,
        id: UUID,
        context: MCPToolContext,
        then answer: @escaping (Bool) -> Void
    ) {
        let group = SidebarGroupStore.shared.resolveGroup(surfaceId: id, pwd: tab.pwd)
        MCPPermissionStore.shared.decide(
            MCPPermission.Request(
                capability: capability, surface: id, group: group?.id.uuidString),
            client: context.client,
            clientName: context.clientName,
            tabTitle: displayTitle(tab),
            then: answer)
    }

    // MARK: The answer, as a value

    /// Every open terminal, in the order the sidebar shows them.
    ///
    /// Gathered across every window because a reader runs several, and an
    /// agent asked to look at "the other terminal" has no way to know which
    /// window it is in. Deduplicated by window identity: each window's
    /// `SidebarTabManager` lists the whole tab group, so walking `NSApp.windows`
    /// meets every tab once per sibling.
    static func snapshots() -> [MCPTerminalSnapshot] {
        var seen: Set<ObjectIdentifier> = []
        var tabs: [SidebarTabModel] = []

        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController,
                  let manager = controller.sidebarTabManager
            else { continue }

            for tab in manager.models where seen.insert(tab.id).inserted {
                /// A model whose window has gone is a row the next refresh
                /// removes, and one with no surface id cannot be named back —
                /// neither is a terminal anything here can act on.
                guard tab.window != nil, tab.surfaceId != nil else { continue }
                tabs.append(tab)
            }
        }

        let ordered = SidebarGroupStore.shared.sorted(tabs, id: { $0.surfaceId })
        return ordered.map(snapshot)
    }

    /// One tab flattened into a value, so the shape `list_terminals` answers
    /// with can be asserted without a window on screen.
    static func snapshot(_ tab: SidebarTabModel) -> MCPTerminalSnapshot {
        let id = tab.surfaceId
        let group = id.flatMap {
            SidebarGroupStore.shared.resolveGroup(surfaceId: $0, pwd: tab.pwd)
        }

        return MCPTerminalSnapshot(
            id: id ?? UUID(),
            title: displayTitle(tab),
            workingDirectory: tab.pwd,
            foregroundProcess: tab.foregroundName,
            isIdle: TerminalIdleCheck.isIdle(foregroundPID: tab.foregroundPID),
            /// The row's own answer first, then the centre it came from. The
            /// model is written by the sidebar's refresh, so a tab whose row
            /// has not been through one yet still reports a port the centre
            /// already knows about.
            devServerPort: tab.devServerPort
                ?? DevServerCenter.shared.port(forPID: tab.foregroundPID),
            groupID: group?.id.uuidString,
            groupName: group?.name,
            /// The checkout the tab is standing in, which for a linked
            /// worktree is the worktree's own folder — `gitInfo` walks up to
            /// `.git` and follows the file a worktree has there, without
            /// running git.
            worktreePath: tab.repoRoot,
            worktreeBranch: tab.gitBranch,
            worktreeRepo: tab.worktreeRepo,
            isManagedWorktree: tab.isInManagedWorktree,
            agent: tab.liveAgent?.rawValue,
            agentState: tab.agentState?.rawValue,
            isFocused: tab.isSelected)
    }

    // MARK: Finding things

    /// The tab a caller named, or nil.
    static func tab(for id: UUID) -> SidebarTabModel? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController,
                  let manager = controller.sidebarTabManager,
                  let match = manager.models.first(where: { $0.surfaceId == id }),
                  match.window != nil
            else { continue }
            return match
        }
        return nil
    }

    /// A group named by id or by name, in that order.
    ///
    /// The id first because it is the one that cannot be ambiguous; the name
    /// because it is the one an agent has read in a `list_terminals` answer
    /// and is likely to type back.
    static func group(named name: String) -> SidebarGroup? {
        let groups = SidebarGroupStore.shared.groups
        if let id = UUID(uuidString: name), let match = groups.first(where: { $0.id == id }) {
            return match
        }
        return groups.first { $0.name == name }
    }

    /// Every worktree the app has already listed, for the repositories its
    /// open terminals are standing in.
    ///
    /// Cache only — `WorktreeCenter.requestList` runs git, and an MCP call is
    /// not a place to start a subprocess the caller cannot wait for. A
    /// worktree Phantom has never listed is answered as "no such worktree",
    /// which is a sentence the agent can act on by naming a path instead.
    static func knownWorktrees() -> [GitWorktree] {
        var roots: Set<String> = []
        for snapshot in snapshots() {
            /// Keyed by the repository's *common* directory, not by the
            /// checkout — that is what `WorktreeCenter` lists under, because
            /// every worktree of a repository shares one and each checkout has
            /// its own. Resolving it reads two small files and runs no git.
            guard let checkout = snapshot.worktreePath,
                  let common = GitCommonDir.resolve(from: checkout)
            else { continue }
            roots.insert(common)
        }
        return roots.flatMap { WorktreeCenter.shared.list(forRoot: $0) }
    }

    // MARK: Rules, kept pure

    /// Which checkout a `worktree` argument names: its path, or its branch.
    ///
    /// Path first, because it is unique and a branch name is not — two
    /// repositories with a `main` are the ordinary case, and matching a branch
    /// first would open a terminal in whichever one git listed first.
    static func worktreePath(named name: String, among worktrees: [GitWorktree]) -> String? {
        if let match = worktrees.first(where: { $0.path == name }) { return match.path }
        return worktrees.first { $0.branch == name }?.path
    }

    /// Where a new terminal starts.
    ///
    /// A named worktree wins over a named directory, which wins over the
    /// group's project root, which wins over the configured home. The order
    /// runs most-specific first for the reason
    /// `TerminalController.newSidebarTab` gives about the worktree panel: a
    /// caller that names a directory is naming the whole point of the tab, and
    /// a group's root silently overriding it opens the terminal somewhere else
    /// entirely.
    static func startDirectory(
        requested: String?,
        worktree: String?,
        group: SidebarGroup?,
        fallback: String
    ) -> String {
        if let worktree, !worktree.isEmpty { return (worktree as NSString).expandingTildeInPath }
        if let requested, !requested.isEmpty {
            return (requested as NSString).expandingTildeInPath
        }
        if let root = group?.projectRoot, !root.isEmpty {
            return (root as NSString).expandingTildeInPath
        }
        return fallback
    }

    /// How many lines `read_output` returns when asked for a number, or for
    /// nothing.
    ///
    /// Capped rather than refused: an agent asking for the whole scrollback is
    /// asking a reasonable question badly, and a ceiling answers it. The floor
    /// is one, because zero lines is an answer nobody can use.
    static func clampedLines(_ asked: Int?) -> Int {
        guard let asked else { return 200 }
        return min(max(asked, 1), 5000)
    }

    /// The last `lines` lines of a scrollback.
    ///
    /// The trailing newline a terminal always leaves is dropped before
    /// counting, so "the last 10 lines" is ten lines of output rather than
    /// nine and a blank.
    static func tail(of text: String, lines: Int) -> String {
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let all = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return trimmed }
        return all.suffix(lines).joined(separator: "\n")
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// What to call a tab in an answer and in the permission sheet.
    ///
    /// The reader's own name for it first, then the window title. A tab the
    /// reader renamed is the one they will recognise in a sheet, and a sheet
    /// naming the wrong terminal is worse than no sheet at all.
    static func displayTitle(_ tab: SidebarTabModel) -> String {
        if let id = tab.surfaceId,
           let name = SidebarGroupStore.shared.tabOverrides[id]?.name,
           !name.isEmpty {
            return name
        }
        return tab.title.isEmpty ? (tab.directoryName ?? "terminal") : tab.title
    }
}

/// One terminal, as the tools describe it.
///
/// A value rather than a read of the live model, so the JSON `list_terminals`
/// answers with can be built and asserted without a window — and so the idle
/// rule that `run_command` turns on is asked of the same snapshot the caller
/// was shown, rather than of the app a moment later.
struct MCPTerminalSnapshot: Equatable {
    var id: UUID
    var title: String
    var workingDirectory: String?

    /// The executable holding the keyboard — `node`, `vim`, or the shell
    /// itself when the terminal is at a prompt. Nil when it cannot be read,
    /// which `isIdle` already counts as busy.
    var foregroundProcess: String?

    var isIdle: Bool
    var devServerPort: Int?
    var groupID: String?
    var groupName: String?
    var worktreePath: String?
    var worktreeBranch: String?
    var worktreeRepo: String?
    var isManagedWorktree: Bool
    var agent: String?
    var agentState: String?
    var isFocused: Bool

    /// Why `run_command` may not type here, or nil when it may.
    ///
    /// A sentence rather than a boolean, because the refusal is the whole
    /// point: an agent told only "busy" retries in a loop, and one told
    /// "`npm` is running" waits.
    var refusalIfBusy: String? {
        guard !isIdle else { return nil }
        return MCPTerminalRefusal.busy(title, running: foregroundProcess)
    }

    var json: JSONValue {
        .object([
            "id": .string(id.uuidString),
            "title": .string(title),
            "working_directory": workingDirectory.map { .string($0) } ?? .null,
            "foreground_process": foregroundProcess.map { .string($0) } ?? .null,
            "idle": .bool(isIdle),
            "dev_server_port": devServerPort.map { .number(Double($0)) } ?? .null,
            "group": groupName.map { .string($0) } ?? .null,
            "group_id": groupID.map { .string($0) } ?? .null,
            "worktree": worktreePath.map { .string($0) } ?? .null,
            "branch": worktreeBranch.map { .string($0) } ?? .null,
            "repo": worktreeRepo.map { .string($0) } ?? .null,
            "managed_worktree": .bool(isManagedWorktree),
            "agent": agent.map { .string($0) } ?? .null,
            "agent_state": agentState.map { .string($0) } ?? .null,
            "focused": .bool(isFocused),
        ])
    }
}

/// What a refused terminal tool says.
///
/// Written for the model that reads it, not for a log. Each sentence says what
/// was refused and what would change it, because the caller is the one thing
/// in the room that can act on the answer — and "permission denied" gives it
/// nothing to act on, so it retries. Kept in one place so the same refusal
/// reads the same wherever it is raised, and so it can be asserted.
enum MCPTerminalRefusal {
    static func missingTerminal(_ tool: String) -> String {
        "\(tool) needs a `terminal` id. Call list_terminals and pass the `id` of the one you mean."
    }

    static var missingCommand: String {
        "run_command needs a `command` to type."
    }

    static var multiLineCommand: String {
        """
        run_command types one command line and presses return, so `command` cannot contain a \
        newline. Call it once per command, and check the first finished with read_output before \
        sending the next.
        """
    }

    static func noSuchTerminal(_ id: UUID) -> String {
        """
        Phantom has no open terminal with id \(id.uuidString). It was probably closed. Call \
        list_terminals for the ids that are open now.
        """
    }

    static func noSuchGroup(_ name: String) -> String {
        """
        Phantom has no sidebar group called “\(name)”. Call list_terminals and use a `group` it \
        reports, or leave `group` out to create the terminal outside every group.
        """
    }

    static func noSuchWorktree(_ name: String) -> String {
        """
        Phantom knows no git worktree at “\(name)”. Call list_terminals and use a `worktree` path \
        it reports, or pass `working_directory` with an absolute path instead.
        """
    }

    static func noSuchAgent(_ name: String) -> String {
        """
        Phantom cannot start “\(name)”. The agents it knows are \
        \(CodingAgent.allCases.map(\.rawValue).joined(separator: ", ")).
        """
    }

    static var couldNotCreate: String {
        "Phantom could not open a new terminal. Ask the reader to check the app is responding."
    }

    static var notRunning: String {
        "Phantom is not ready to open terminals yet. Try again in a moment."
    }

    /// The two sentences a missing grant gets. Split by capability rather than
    /// parameterised, because the thing the reader is being asked for is not
    /// the same thing, and a caller that reads "permission to read" after
    /// asking to run would wait for the wrong sheet.
    static func notAllowedToRead(_ title: String) -> String {
        """
        Phantom has no permission to read “\(title)”. Only the reader can grant it, in the app — \
        no tool here can. Ask them to approve the permission sheet for this terminal, then call \
        read_output again. After a refusal Phantom waits 60 seconds before asking again, and it \
        never raises a second sheet while one is open.
        """
    }

    static func notAllowedToRun(_ title: String) -> String {
        """
        Phantom has no permission to run commands in “\(title)”. Only the reader can grant it, in \
        the app — no tool here can. Ask them to approve the permission sheet for this terminal, \
        then call run_command again. After a refusal Phantom waits 60 seconds before asking \
        again, and it never raises a second sheet while one is open.
        """
    }

    /// The busy refusal, which has to name what is running.
    ///
    /// An agent told only that a terminal is busy has one move left, and it is
    /// to try again; told that `cargo` is running, it can read the output and
    /// wait for it. The unknown case says so rather than inventing a name:
    /// `TerminalIdleCheck` counts a process it cannot read as busy, and the
    /// honest sentence is the one that admits it.
    static func busy(_ title: String, running process: String?) -> String {
        guard let process, !process.isEmpty else {
            return """
                Phantom cannot tell what “\(title)” is running, and counts that as busy rather \
                than typing into it. Read it with read_output to see what it is waiting on, or \
                use create_terminal for a terminal of your own.
                """
        }
        return """
            “\(title)” is busy: `\(process)` has the keyboard. Phantom only types into a terminal \
            sitting at a shell prompt, because anything else swallows the command. Watch it with \
            read_output and call run_command again once `\(process)` exits, or use create_terminal \
            for a terminal of your own.
            """
    }
}
