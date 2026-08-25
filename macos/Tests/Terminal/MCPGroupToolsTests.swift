import Foundation
@testable import Ghostty
import Testing

/// The group half of the MCP server.
///
/// Against a store of its own — `SidebarGroupStore` takes its own file — so a
/// test never writes a group into the reader's real sidebar, and against a
/// terminal that is a value rather than a window.
@MainActor
struct MCPGroupToolsTests {
    private let caller = UUID()
    private let tab = UUID()

    private func store() -> SidebarGroupStore {
        SidebarGroupStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("phantom-mcp-groups-\(UUID().uuidString).json"))
    }

    /// One terminal exists, and it is the only one.
    private func tools(
        _ store: SidebarGroupStore,
        title: String = "npm run dev",
        pwd: String? = nil
    ) -> [MCPToolHandler] {
        MCPGroupTools.all(store: store) { [tab] id in
            id == tab ? MCPGroupTools.Terminal(title: title, pwd: pwd) : nil
        }
    }

    private func tool(
        _ name: String,
        _ store: SidebarGroupStore,
        title: String = "npm run dev",
        pwd: String? = nil
    ) -> MCPToolHandler {
        tools(store, title: title, pwd: pwd).first { $0.tool.name == name }!
    }

    private func run(
        _ handler: MCPToolHandler,
        _ arguments: [String: JSONValue],
        client: AnyObject
    ) -> MCPToolResult? {
        var result: MCPToolResult?
        handler.run(
            MCPToolContext(
                callerSurface: caller,
                clientName: "test",
                client: ObjectIdentifier(client),
                arguments: arguments)
        ) { result = $0 }
        return result
    }

    private func refusal(_ result: MCPToolResult?) -> String? {
        guard case .refused(let reason)? = result else { return nil }
        return reason
    }

    private func text(_ result: MCPToolResult?) -> String? {
        guard case .text(let value)? = result else { return nil }
        return value
    }

    private func json(_ result: MCPToolResult?) -> [String: JSONValue]? {
        guard case .json(let value)? = result else { return nil }
        return value.object
    }

    // MARK: What is on offer

    /// Listing lives here after all. It was left to the terminals at first,
    /// on the grounds that it lists tabs — and it was written by nobody,
    /// while every refusal in this file already pointed a model at it.
    @Test func theToolsAreListingAndTheTwoThatChangeAGroup() {
        let names = tools(store()).map(\.tool.name)
        #expect(names == [
            "list_groups", "list_theme_colors", "create_group", "update_group",
            "move_to_group",
        ])
    }

    @Test func everyDescriptionSaysWhenToReachForIt() {
        for handler in tools(store()) {
            let text = handler.tool.description
            /// "Use it" was the only phrasing when this rule was written, and
            /// "Call it when…" says the same thing — so the check widened
            /// rather than the description bending to fit the check.
            #expect(
                text.contains("Use it") || text.contains("Call it"),
                "\(handler.tool.name) never says when to use it")
        }
    }

    @Test func everySchemaNamesWhatItCannotDoWithout() {
        let required = tools(store()).reduce(into: [String: [JSONValue]]()) {
            $0[$1.tool.name] = $1.tool.schema.object?["required"]?.array
        }

        #expect(required["create_group"] == [.string("name")])
        #expect(required["move_to_group"] == [.string("terminal"), .string("group")])
    }

    // MARK: create_group

    /// The id it answers with is the one `move_to_group` takes back.
    @Test func creatingAGroupHandsBackTheIdThatAddressesIt() {
        let store = store()
        let answer = json(run(
            tool("create_group", store), ["name": .string("Aurora")], client: store))

        let id = answer?["id"]?.string.flatMap(UUID.init(uuidString:))
        #expect(store.groups.count == 1)
        #expect(id == store.groups[0].id)
        #expect(answer?["name"] == .string("Aurora"))
        #expect(answer?["project_root"] == .null)
    }

    @Test func aGroupWithNoIconWearsTheOneTheSidebarsOwnDialogStartsFrom() {
        let store = store()
        _ = run(tool("create_group", store), ["name": .string("Aurora")], client: store)

        #expect(store.groups[0].icon == MCPGroupTools.defaultIcon)
    }

    @Test func creatingAGroupRefusesANameWithNothingInIt() {
        let store = store()
        let reason = refusal(run(
            tool("create_group", store), ["name": .string("   ")], client: store))

        #expect(reason?.contains("“name”") == true)
        #expect(store.groups.isEmpty)
    }

    /// A group that is already there is a refusal that says so — and says
    /// which id to use instead, since that is what the caller wanted.
    @Test func aGroupThatIsAlreadyThereIsRefusedByName() {
        let store = store()
        let handler = tool("create_group", store)
        _ = run(handler, ["name": .string("Aurora")], client: store)

        let reason = refusal(run(handler, ["name": .string("aurora")], client: store))

        #expect(reason?.contains("already has a group") == true)
        #expect(reason?.contains(store.groups[0].id.uuidString) == true)
        #expect(store.groups.count == 1)
    }

    // MARK: Icons

    /// An SF Symbol name this build cannot draw is an empty square on the
    /// sidebar for as long as the group lives, and the renderer has nobody
    /// to tell.
    @Test func anIconThatWouldDrawNothingIsRefused() {
        #expect(MCPGroupTools.iconRefusal("not.a.symbol.at.all")?.contains("SF Symbol") == true)
        #expect(MCPGroupTools.iconRefusal("agent:aider")?.contains("agent") == true)
    }

    @Test func theThreeFormsAnIconComesInAreAccepted() {
        #expect(MCPGroupTools.iconRefusal("folder") == nil)
        #expect(MCPGroupTools.iconRefusal("🚀") == nil)
        #expect(MCPGroupTools.iconRefusal(SidebarIconID.id(for: .claude)) == nil)
        #expect(MCPGroupTools.iconRefusal("") == nil)
    }

    @Test func creatingAGroupRefusesAnIconThatWouldNotDraw() {
        let store = store()
        let reason = refusal(run(
            tool("create_group", store),
            ["name": .string("Aurora"), "icon": .string("not.a.symbol.at.all")],
            client: store))

        #expect(reason != nil)
        #expect(store.groups.isEmpty, "nothing is created when the icon is refused")
    }

    // MARK: Project roots

    @Test func aProjectRootIsStoredTheWayTheReadersOwnPickerStoresIt() {
        let store = store()
        let answer = json(run(
            tool("create_group", store),
            ["name": .string("Phantom"), "project_root": .string("~")],
            client: store))

        #expect(answer?["project_root"] == .string("~"))
        #expect(store.groups[0].kind == .project(root: "~"))
    }

    @Test func aProjectRootThatIsNotThereIsRefused() {
        let store = store()
        let missing = NSTemporaryDirectory() + "phantom-mcp-nowhere-\(UUID().uuidString)"

        let reason = refusal(run(
            tool("create_group", store),
            ["name": .string("Phantom"), "project_root": .string(missing)],
            client: store))

        #expect(reason?.contains("no folder at") == true)
        #expect(store.groups.isEmpty)
    }

    @Test func aRelativeProjectRootIsRefused() {
        let store = store()
        let reason = refusal(run(
            tool("create_group", store),
            ["name": .string("Phantom"), "project_root": .string("Projects/phantom")],
            client: store))

        #expect(reason?.contains("absolute") == true)
    }

    // MARK: move_to_group

    @Test func movingATerminalFilesItUnderTheGroup() {
        let store = store()
        let group = store.createGroup(name: "Aurora")

        let answer = json(run(
            tool("move_to_group", store),
            ["terminal": .string(tab.uuidString), "group": .string(group.id.uuidString)],
            client: store))

        #expect(store.assignments[tab]?.groupId == group.id)
        #expect(answer?["terminal"] == .string(tab.uuidString))
        #expect(answer?["group"] == .string(group.id.uuidString))
        #expect(answer?["moved"]?.string?.contains("npm run dev") == true)
    }

    /// Already where it was asked to go is not an error, and not a silence
    /// either: the caller is told the arrangement it wanted is the one there.
    @Test func aTerminalAlreadyInThatGroupIsToldSo() {
        let store = store()
        let group = store.createGroup(name: "Aurora")
        let handler = tool("move_to_group", store)
        let arguments: [String: JSONValue] = [
            "terminal": .string(tab.uuidString),
            "group": .string(group.id.uuidString),
        ]
        _ = run(handler, arguments, client: store)

        let answer = text(run(handler, arguments, client: store))

        #expect(answer?.contains("already in") == true)
    }

    @Test func movingATerminalNobodyHasIsRefused() {
        let store = store()
        let group = store.createGroup(name: "Aurora")
        let stranger = UUID()

        let reason = refusal(run(
            tool("move_to_group", store),
            ["terminal": .string(stranger.uuidString), "group": .string(group.id.uuidString)],
            client: store))

        #expect(reason?.contains(stranger.uuidString) == true)
        #expect(reason?.contains("list_terminals") == true)
        #expect(store.assignments.isEmpty)
    }

    @Test func movingIntoAGroupThatDoesNotExistIsRefused() {
        let store = store()
        let stranger = UUID()

        let reason = refusal(run(
            tool("move_to_group", store),
            ["terminal": .string(tab.uuidString), "group": .string(stranger.uuidString)],
            client: store))

        #expect(reason?.contains("list_groups") == true)
        #expect(store.assignments.isEmpty)
    }

    /// The ids handed out are UUIDs, so a name is not one of them — and the
    /// refusal says where the real one comes from.
    @Test func anIdThatIsNotOneOfOursIsRefusedWithWhereToGetOne() {
        let store = store()
        let reason = refusal(run(
            tool("move_to_group", store),
            ["terminal": .string(tab.uuidString), "group": .string("Aurora")],
            client: store))

        #expect(reason?.contains("Aurora") == true)
        #expect(reason?.contains("list_groups") == true)
    }

    @Test func movingWithNoArgumentsAtAllSaysWhichOneIsMissing() {
        let store = store()
        let reason = refusal(run(tool("move_to_group", store), [:], client: store))

        #expect(reason?.contains("“terminal”") == true)
    }

    // MARK: Listing

    /// The tool every refusal in this file points at. A model given a group
    /// id that no longer exists is told to look here, so "here" has to exist.
    @Test func listGroupsIsOffered() {
        let names = MCPGroupTools.all(store: store(), terminal: { _ in nil })
            .map(\.tool.name)
        #expect(names.contains("list_groups"))
    }

    /// It asks for nothing, so a model cannot be refused for calling it
    /// without arguments — which is the only way it is ever called.
    @Test func listGroupsTakesNoArguments() throws {
        let tool = try #require(
            MCPGroupTools.all(store: store(), terminal: { _ in nil })
                .first { $0.tool.name == "list_groups" })

        let required = tool.tool.schema.object?["required"]?.array
        #expect(required?.isEmpty == true)
    }

    // MARK: Naming a group

    /// One vocabulary across every tool that takes a group. `create_terminal`
    /// took a name from the start and the group tools took only an id, and a
    /// model that succeeds with a name in one will try a name in the other.
    @Test func aGroupIsFoundByIdOrByName() {
        let store = store()
        let group = store.createGroup(name: "Aurora", icon: "brain", kind: .manual)

        #expect(MCPGroupTools.group(named: group.id.uuidString, in: store)?.id == group.id)
        #expect(MCPGroupTools.group(named: "Aurora", in: store)?.id == group.id)
        #expect(MCPGroupTools.group(named: "aurora", in: store)?.id == group.id)
        #expect(MCPGroupTools.group(named: "  Aurora  ", in: store)?.id == group.id)
        #expect(MCPGroupTools.group(named: "Nope", in: store) == nil)
    }

    /// The id is tried first, because a name is not unique across time — a
    /// group can be renamed to what another one was called — while an id is
    /// the thing this app handed out.
    @Test func anIdWinsOverANameThatLooksLikeOne() {
        let store = store()
        let first = store.createGroup(name: "One", icon: "folder", kind: .manual)
        let second = store.createGroup(name: first.id.uuidString, icon: "folder", kind: .manual)

        #expect(MCPGroupTools.group(named: first.id.uuidString, in: store)?.id == first.id)
        #expect(MCPGroupTools.group(named: second.name, in: store)?.id == first.id)
    }
}
