import Foundation
import Testing

@testable import Ghostty

/// The permission rules, which are the only thing standing between an agent
/// and a terminal's scrollback.
struct MCPPermissionTests {
    private let tabA = UUID()
    private let tabB = UUID()

    private func grant(
        _ capability: MCPPermission.Capability = .read,
        _ scope: MCPPermission.Scope,
        surface: UUID? = nil,
        group: String? = nil
    ) -> MCPPermission.Grant {
        MCPPermission.Grant(
            capability: capability, scope: scope, surface: surface, group: group)
    }

    private func request(
        _ capability: MCPPermission.Capability = .read,
        surface: UUID? = nil,
        group: String? = nil
    ) -> MCPPermission.Request {
        MCPPermission.Request(capability: capability, surface: surface, group: group)
    }

    @Test func nothingIsAllowedByDefault() {
        #expect(!MCPPermission.isAllowed(request(surface: tabA), by: []))
    }

    @Test func aTabGrantAnswersForThatTabAlone() {
        let held = [grant(.read, .tab, surface: tabA)]
        #expect(MCPPermission.isAllowed(request(surface: tabA), by: held))
        #expect(!MCPPermission.isAllowed(request(surface: tabB), by: held))
    }

    /// The request carries the *target's* group rather than the caller
    /// claiming one, because the caller is often in a different tab than the
    /// one it is reaching for.
    @Test func aGroupGrantAnswersForTheSameGroup() {
        let held = [grant(.read, .group, surface: tabA, group: "work")]
        #expect(MCPPermission.isAllowed(request(surface: tabB, group: "work"), by: held))
        #expect(!MCPPermission.isAllowed(request(surface: tabB, group: "other"), by: held))
        #expect(!MCPPermission.isAllowed(request(surface: tabB), by: held))
    }

    @Test func allAnswersForAnything() {
        let held = [grant(.read, .all)]
        #expect(MCPPermission.isAllowed(request(surface: tabA), by: held))
        #expect(MCPPermission.isAllowed(request(surface: tabB, group: "work"), by: held))
        #expect(MCPPermission.isAllowed(request(), by: held))
    }

    /// The two questions are kept apart on purpose: how much, and what for.
    /// Folded together, a grant to read would end up allowing a command.
    @Test func readingIsNotRunning() {
        let held = [grant(.read, .all)]
        #expect(!MCPPermission.isAllowed(request(.run, surface: tabA), by: held))
    }

    /// Ordered narrow to wide, and the order is load-bearing — `all` answers
    /// for a tab without that rule being written twice.
    @Test func theScopesAreOrderedByReach() {
        #expect(MCPPermission.Scope.tab < .group)
        #expect(MCPPermission.Scope.group < .all)
    }

    /// A prompt that names the wrong terminal is worse than no prompt: the
    /// reader is being asked to authorise something specific.
    @Test func theQuestionNamesTheClientAndTheTab() {
        let text = MCPPermission.question(
            client: "Claude Code", capability: .read, tabTitle: "aurora ~ tests")
        #expect(text.contains("Claude Code"))
        #expect(text.contains("aurora ~ tests"))
        #expect(!text.contains("this terminal"))
    }

    @Test func theQuestionStillReadsWithNothingToName() {
        let text = MCPPermission.question(client: nil, capability: .run, tabTitle: nil)
        #expect(text.contains("An agent"))
        #expect(text.contains("run commands"))
    }

    // MARK: The store

    @MainActor
    private func store() -> MCPPermissionStore {
        let defaults = UserDefaults(suiteName: "mcp-tests-\(UUID().uuidString)")!
        return MCPPermissionStore(defaults: defaults)
    }

    @MainActor
    @Test func aGrantedRequestIsAllowedWithoutAskingAgain() async {
        let store = store()
        let client = ObjectIdentifier(store)

        var asked = 0
        var allowed: Bool?

        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "tab"
        ) { allowed = $0 }

        asked += store.pending == nil ? 0 : 1
        store.pending?.answer(.tab, true)
        #expect(allowed == true)
        #expect(asked == 1)

        allowed = nil
        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "tab"
        ) { allowed = $0 }

        #expect(allowed == true)
        #expect(store.pending == nil, "a settled request must not ask again")
    }

    /// A refusal holds for a while, so an agent that asks in a loop is turned
    /// away without a sheet. A prompt that appears ten times is one that gets
    /// accepted without being read.
    @MainActor
    @Test func aRefusalIsNotAskedAgainImmediately() {
        let store = store()
        let client = ObjectIdentifier(store)

        var allowed: Bool?
        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "tab"
        ) { allowed = $0 }
        store.pending?.answer(nil, false)
        #expect(allowed == false)

        allowed = nil
        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "tab"
        ) { allowed = $0 }

        #expect(allowed == false)
        #expect(store.pending == nil, "the second ask must not reach the reader")
    }

    /// Granted for one call, so it cannot be waiting for the reader tomorrow.
    @MainActor
    @Test func onceIsNotWrittenDown() {
        let store = store()
        let client = ObjectIdentifier(store)

        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "tab"
        ) { _ in }
        store.pending?.answer(.tab, false)

        #expect(store.grants.isEmpty)

        store.forget(client: client)
        var allowed: Bool?
        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "tab"
        ) { allowed = $0 }
        #expect(allowed == nil || allowed == false, "the grant died with the connection")
    }

    @MainActor
    @Test func alwaysSurvivesAndCanBeRevoked() {
        let store = store()
        store.decide(
            request(surface: tabA),
            client: ObjectIdentifier(store), clientName: "test", tabTitle: "tab"
        ) { _ in }
        store.pending?.answer(.all, true)

        #expect(store.grants.count == 1)
        store.revoke(store.grants[0])
        #expect(store.grants.isEmpty)
    }

    /// Two sheets stacked over each other is how a reader answers the one
    /// they did not read.
    @MainActor
    @Test func onlyOneQuestionIsOnScreenAtATime() {
        let store = store()
        let client = ObjectIdentifier(store)

        store.decide(
            request(surface: tabA), client: client, clientName: "test", tabTitle: "a"
        ) { _ in }

        var second: Bool?
        store.decide(
            request(surface: tabB), client: client, clientName: "test", tabTitle: "b"
        ) { second = $0 }

        #expect(second == false)
        #expect(store.pending?.tabTitle == "a")
    }
}
