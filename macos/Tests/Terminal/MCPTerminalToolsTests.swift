import Foundation
import Testing

@testable import Ghostty

/// The terminal tools, in the parts that hold without a window: the schemas an
/// agent reads before it calls anything, the mapping from app state to the
/// JSON it gets back, the idle rule `run_command` turns on, and the refusals —
/// which are the whole interface when a tool says no.
@MainActor
struct MCPTerminalToolsTests {
    private func snapshot(
        id: UUID = UUID(),
        title: String = "aurora",
        workingDirectory: String? = "/Users/reader/aurora",
        foregroundProcess: String? = "zsh",
        isIdle: Bool = true,
        devServerPort: Int? = nil,
        groupID: String? = nil,
        groupName: String? = nil,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        worktreeRepo: String? = nil,
        isManagedWorktree: Bool = false,
        agent: String? = nil,
        agentState: String? = nil,
        isFocused: Bool = false
    ) -> MCPTerminalSnapshot {
        MCPTerminalSnapshot(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
            foregroundProcess: foregroundProcess,
            isIdle: isIdle,
            devServerPort: devServerPort,
            groupID: groupID,
            groupName: groupName,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            worktreeRepo: worktreeRepo,
            isManagedWorktree: isManagedWorktree,
            agent: agent,
            agentState: agentState,
            isFocused: isFocused)
    }

    private func field(_ value: JSONValue, _ name: String) -> JSONValue? {
        value.object?[name]
    }

    // MARK: The tools on offer

    @Test func theToolsOnOfferAreTheOnesDocumented() {
        let names = MCPTerminalTools.all.map(\.tool.name)
        #expect(names == [
            "list_terminals", "read_output", "create_terminal", "run_command",
            "focus_terminal", "update_terminal",
        ])
    }

    /// Every description is written for the model that has to decide whether
    /// to reach for the tool, so each says *when* to use it and not only what
    /// it does.
    @Test func everyToolSaysWhenToUseIt() {
        for handler in MCPTerminalTools.all {
            #expect(handler.tool.description.count > 120, "\(handler.tool.name) is too thin")
        }
    }

    /// The ids handed out have to be the ids taken back, or an agent that
    /// listed the terminals cannot act on one.
    @Test func everyToolThatTakesATerminalSpellsItTheSameWay() {
        for name in ["read_output", "run_command", "focus_terminal"] {
            let handler = MCPTerminalTools.all.first { $0.tool.name == name }
            let properties = field(handler!.tool.schema, "properties")
            #expect(properties?.object?["terminal"] != nil, "\(name) takes no `terminal`")
        }
    }

    @Test func runCommandRequiresBothATerminalAndACommand() {
        let handler = MCPTerminalTools.all.first { $0.tool.name == "run_command" }
        let required = field(handler!.tool.schema, "required")?.array?.compactMap(\.string)
        #expect(required == ["terminal", "command"])
    }

    /// `list_terminals` takes nothing: an agent's first call must not need a
    /// value it can only get from a call it has not made yet.
    @Test func listTerminalsTakesNoArguments() {
        let properties = field(MCPTerminalTools.listTerminals.tool.schema, "properties")
        #expect(properties?.object?.isEmpty == true)
    }

    /// Every argument `create_terminal` takes is optional — the useful default
    /// is a terminal in the reader's home, and an agent should not have to
    /// know a path to open one.
    @Test func createTerminalRequiresNothing() {
        let required = field(MCPTerminalTools.createTerminal.tool.schema, "required")?.array
        #expect(required?.isEmpty == true)
    }

    /// The agent list comes from `CodingAgent` rather than being spelled here,
    /// so a fifth agent reaches MCP without anybody remembering to add it.
    @Test func createTerminalOffersTheAgentsTheAppKnows() {
        let properties = field(MCPTerminalTools.createTerminal.tool.schema, "properties")
        let cases = properties?.object?["agent"]?.object?["enum"]?.array?.compactMap(\.string)
        #expect(cases == CodingAgent.allCases.map(\.rawValue))
    }

    // MARK: What a terminal looks like in an answer

    @Test func aTerminalCarriesEverythingNeededToChooseOne() {
        let id = UUID()
        let json = snapshot(
            id: id,
            title: "aurora ~ tests",
            foregroundProcess: "node",
            isIdle: false,
            devServerPort: 5173,
            groupName: "Aurora",
            worktreePath: "/Users/reader/wt/aurora-feat",
            worktreeBranch: "feat/mcp",
            worktreeRepo: "aurora",
            isManagedWorktree: true,
            agent: "claude",
            agentState: "working",
            isFocused: true
        ).json

        #expect(field(json, "id") == .string(id.uuidString))
        #expect(field(json, "title") == .string("aurora ~ tests"))
        #expect(field(json, "foreground_process") == .string("node"))
        #expect(field(json, "idle") == .bool(false))
        #expect(field(json, "dev_server_port") == .number(5173))
        #expect(field(json, "group") == .string("Aurora"))
        #expect(field(json, "worktree") == .string("/Users/reader/wt/aurora-feat"))
        #expect(field(json, "branch") == .string("feat/mcp"))
        #expect(field(json, "repo") == .string("aurora"))
        #expect(field(json, "managed_worktree") == .bool(true))
        #expect(field(json, "agent") == .string("claude"))
        #expect(field(json, "agent_state") == .string("working"))
        #expect(field(json, "focused") == .bool(true))
    }

    /// Absent is spelled `null` rather than left out, so a caller reading the
    /// answer sees the field it was promised and knows the app had no value —
    /// which is a different thing from the app not having the field.
    @Test func whatIsNotKnownIsSaidToBeNull() {
        let json = snapshot(devServerPort: nil, groupName: nil, agent: nil).json
        #expect(field(json, "dev_server_port") == .null)
        #expect(field(json, "group") == .null)
        #expect(field(json, "agent") == .null)
        #expect(field(json, "agent_state") == .null)
    }

    /// The id in an answer is a surface UUID, which is what
    /// `MCPToolContext.surface` parses back out of an argument.
    @Test func theIdItAnswersWithIsTheIdItAccepts() throws {
        let id = UUID()
        let spelled = try #require(snapshot(id: id).json.object?["id"]?.string)
        let context = MCPToolContext(
            callerSurface: nil,
            clientName: nil,
            client: ObjectIdentifier(MCPPermissionStore.shared),
            arguments: ["terminal": .string(spelled)])
        #expect(context.surface("terminal") == id)
    }

    // MARK: The idle rule

    @Test func anIdleTerminalIsNotRefused() {
        let terminal = snapshot(foregroundProcess: "zsh", isIdle: true)
        #expect(terminal.refusalIfBusy == nil)
    }

    /// The refusal has to name what is running, or the agent's only remaining
    /// move is to try again.
    @Test func aBusyTerminalIsRefusedAndSaysWhatIsRunning() throws {
        let terminal = snapshot(title: "aurora", foregroundProcess: "cargo", isIdle: false)
        let refusal = try #require(terminal.refusalIfBusy)
        #expect(refusal.contains("cargo"))
        #expect(refusal.contains("aurora"))
        #expect(refusal.contains("read_output"))
    }

    /// `TerminalIdleCheck` counts a process it cannot read as busy, and the
    /// honest refusal admits that rather than inventing a name.
    @Test func anUnreadableProcessIsRefusedAsUnknown() throws {
        let terminal = snapshot(foregroundProcess: nil, isIdle: false)
        let refusal = try #require(terminal.refusalIfBusy)
        #expect(refusal.contains("cannot tell"))
        #expect(refusal.contains("read_output"))
        #expect(refusal.contains("create_terminal"))
    }

    /// The trimming `tail` applies has to be on both sides of the comparison,
    /// or a scrollback shorter than the number asked for reports itself
    /// truncated over its own trailing newline.
    @Test func aWholeScrollbackIsNotReportedAsTruncated() {
        let whole = "one\ntwo\n"
        let text = MCPTerminalTools.tail(of: whole, lines: 200)
        let complete = MCPTerminalTools.tail(of: whole, lines: .max)
        #expect(text.count == complete.count)
        #expect(MCPTerminalTools.tail(of: whole, lines: 1).count < complete.count)
    }

    /// The rule this spec settled on, asserted where `run_command` reads it:
    /// unknown counts as busy.
    @Test func unknownCountsAsBusy() {
        #expect(!TerminalIdleCheck.isIdle(foregroundPID: nil))
        #expect(TerminalIdleCheck.isShell("zsh"))
        #expect(!TerminalIdleCheck.isShell("node"))
    }

    // MARK: The refusals

    /// A refusal says what was refused and what would change it. "Permission
    /// denied" would give the caller nothing to act on, so it would retry.
    @Test func aReadRefusalSaysWhoCanGrantItAndWhatToDoNext() {
        let refusal = MCPTerminalRefusal.notAllowedToRead("aurora ~ tests")
        #expect(refusal.contains("aurora ~ tests"))
        #expect(refusal.contains("reader"))
        #expect(refusal.contains("read_output"))
        #expect(refusal.contains("60 seconds"))
    }

    @Test func aRunRefusalNamesRunningRatherThanReading() {
        let refusal = MCPTerminalRefusal.notAllowedToRun("aurora ~ tests")
        #expect(refusal.contains("run commands"))
        #expect(refusal.contains("run_command"))
        #expect(!refusal.contains("read_output"))
    }

    /// No tool grants permission, and the refusal has to say so — otherwise an
    /// agent goes looking for the tool that would.
    @Test func everyPermissionRefusalSaysNoToolCanGrantIt() {
        for refusal in [
            MCPTerminalRefusal.notAllowedToRead("a"),
            MCPTerminalRefusal.notAllowedToRun("a"),
        ] {
            #expect(refusal.contains("no tool here can"))
        }
    }

    @Test func aClosedTerminalIsRefusedByPointingBackAtTheList() {
        let id = UUID()
        let refusal = MCPTerminalRefusal.noSuchTerminal(id)
        #expect(refusal.contains(id.uuidString))
        #expect(refusal.contains("list_terminals"))
    }

    @Test func aMissingIdNamesTheToolThatWantedIt() {
        #expect(MCPTerminalRefusal.missingTerminal("read_output").contains("read_output"))
        #expect(MCPTerminalRefusal.missingTerminal("read_output").contains("list_terminals"))
    }

    /// One grant, one command. `ClaudeSession.run` presses return itself, so a
    /// newline would run several commands off a sheet that named one terminal.
    @Test func aMultiLineCommandIsRefusedWithTheReasonSpelledOut() {
        let refusal = MCPTerminalRefusal.multiLineCommand
        #expect(refusal.contains("newline"))
        #expect(refusal.contains("once per command"))
    }

    @Test func anUnknownAgentIsRefusedWithTheOnesTheAppKnows() {
        let refusal = MCPTerminalRefusal.noSuchAgent("cursor")
        #expect(refusal.contains("cursor"))
        for agent in CodingAgent.allCases {
            #expect(refusal.contains(agent.rawValue))
        }
    }

    @Test func anUnknownWorktreeOffersThePathInstead() {
        let refusal = MCPTerminalRefusal.noSuchWorktree("feat/nope")
        #expect(refusal.contains("feat/nope"))
        #expect(refusal.contains("working_directory"))
    }

    // MARK: Naming a worktree

    private func worktree(path: String, branch: String?) -> GitWorktree {
        GitWorktree(
            path: path,
            head: nil,
            branch: branch,
            isMain: false,
            isBare: false,
            isDetached: branch == nil,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil)
    }

    @Test func aWorktreeIsFoundByPathOrByBranch() {
        let all = [
            worktree(path: "/wt/aurora-main", branch: "main"),
            worktree(path: "/wt/aurora-feat", branch: "feat/mcp"),
        ]
        #expect(MCPTerminalTools.worktreePath(named: "/wt/aurora-feat", among: all)
            == "/wt/aurora-feat")
        #expect(MCPTerminalTools.worktreePath(named: "feat/mcp", among: all) == "/wt/aurora-feat")
        #expect(MCPTerminalTools.worktreePath(named: "feat/nope", among: all) == nil)
    }

    /// A path is unique and a branch name is not — two repositories with a
    /// `main` is the ordinary case — so the path is matched first.
    @Test func aPathWinsOverABranchOfTheSameName() {
        let all = [
            worktree(path: "main", branch: "release"),
            worktree(path: "/wt/other", branch: "main"),
        ]
        #expect(MCPTerminalTools.worktreePath(named: "main", among: all) == "main")
    }

    // MARK: Where a new terminal starts

    private func projectGroup(root: String) -> SidebarGroup {
        SidebarGroup(name: "Aurora", kind: .project(root: root))
    }

    @Test func aNamedWorktreeWinsOverEverythingElse() {
        let directory = MCPTerminalTools.startDirectory(
            requested: "/asked",
            worktree: "/wt/aurora-feat",
            group: projectGroup(root: "/repo"),
            fallback: "/home")
        #expect(directory == "/wt/aurora-feat")
    }

    /// A caller naming a directory is naming the point of the tab, so a
    /// group's root must not silently override it.
    @Test func aNamedDirectoryWinsOverTheGroupsRoot() {
        let directory = MCPTerminalTools.startDirectory(
            requested: "/asked", worktree: nil,
            group: projectGroup(root: "/repo"), fallback: "/home")
        #expect(directory == "/asked")
    }

    @Test func aProjectGroupLendsItsRoot() {
        let directory = MCPTerminalTools.startDirectory(
            requested: nil, worktree: nil, group: projectGroup(root: "/repo"), fallback: "/home")
        #expect(directory == "/repo")
    }

    /// A manual group names no repository, so there is nothing to borrow and
    /// the fallback stands.
    @Test func aManualGroupLendsNothing() {
        let group = SidebarGroup(name: "Scratch", kind: .manual)
        let directory = MCPTerminalTools.startDirectory(
            requested: nil, worktree: nil, group: group, fallback: "/home")
        #expect(directory == "/home")
    }

    @Test func nothingNamedFallsBackToTheConfiguredHome() {
        let directory = MCPTerminalTools.startDirectory(
            requested: nil, worktree: nil, group: nil, fallback: "/home")
        #expect(directory == "/home")
    }

    @Test func anEmptyStringIsTreatedAsNothingNamed() {
        let directory = MCPTerminalTools.startDirectory(
            requested: "", worktree: "", group: nil, fallback: "/home")
        #expect(directory == "/home")
    }

    // MARK: The tail of a scrollback

    private let scrollback = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"

    @Test func theTailIsTheLastLines() {
        #expect(MCPTerminalTools.tail(of: scrollback, lines: 3) == "line 8\nline 9\nline 10")
    }

    /// The trailing newline a terminal always leaves is dropped before
    /// counting, so ten lines asked for is ten lines of output.
    @Test func theTrailingNewlineIsNotCountedAsALine() {
        #expect(MCPTerminalTools.tail(of: scrollback, lines: 10) == scrollback.dropLast())
        #expect(MCPTerminalTools.lineCount(MCPTerminalTools.tail(of: scrollback, lines: 10)) == 10)
    }

    @Test func askingForMoreThanThereIsGivesWhatThereIs() {
        #expect(MCPTerminalTools.tail(of: "one\ntwo", lines: 500) == "one\ntwo")
        #expect(MCPTerminalTools.tail(of: "", lines: 10).isEmpty)
        #expect(MCPTerminalTools.lineCount("") == 0)
    }

    /// Capped rather than refused: an agent asking for the whole scrollback is
    /// asking a reasonable question badly, and a ceiling answers it.
    @Test func theLineCountIsClampedRatherThanRefused() {
        #expect(MCPTerminalTools.clampedLines(nil) == 200)
        #expect(MCPTerminalTools.clampedLines(20) == 20)
        #expect(MCPTerminalTools.clampedLines(1_000_000) == 5000)
        #expect(MCPTerminalTools.clampedLines(0) == 1)
        #expect(MCPTerminalTools.clampedLines(-5) == 1)
    }

    // MARK: The registry

    /// The terminal tools reach the client through the one registry, and a
    /// tool nobody can list is a tool nobody can call.
    @Test func theTerminalToolsAreInTheRegistry() {
        let registered = Set(MCPToolRegistry.all.map(\.tool.name))
        for handler in MCPTerminalTools.all {
            #expect(registered.contains(handler.tool.name))
        }
    }

    /// Each name is spelled once. Two handlers under one name and `MCPService`
    /// answers with whichever it met first.
    @Test func noTwoToolsShareAName() {
        let names = MCPToolRegistry.all.map(\.tool.name)
        #expect(names.count == Set(names).count)
    }
}
