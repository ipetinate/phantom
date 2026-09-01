import Foundation
@testable import Ghostty
import Testing

/// The one list of agents whose hooks this app installs.
///
/// Nothing here calls `install()` or `uninstall()`. The suite is hosted inside
/// the app, so a test that installed would write into the developer's own
/// `~/.claude/settings.json` — the hazard the launch path guards against with
/// `MCPServer.isTesting`. What is asserted is the shape of the list, which is
/// the part that was wrong: three hand-written copies of six agents, one of
/// which covered four.
@MainActor
struct AgentHooksRegistrationTests {
    /// The assertion the MCP side already makes, for the same reason: an agent
    /// missing from both sides is an agent whose hooks nobody installs and
    /// nobody decided not to install.
    @Test func everyAgentIsOffered() {
        let offered = Set(AgentHooksRegistration.agents.map(\.id))
        let declined = AgentHooksRegistration.withoutInstaller

        #expect(offered.union(declined) == Set(CodingAgent.allCases))
        #expect(offered.isDisjoint(with: declined))
    }

    /// The bug this registry was built to end: the Agents pane refreshed
    /// Claude, Codex, OpenCode and Antigravity on activation, and left Kimi and
    /// Pi to a line that had been pasted inside Antigravity's install closure.
    /// A status read as a whole cannot cover four sixths of itself.
    @Test func statusAnswersForEveryAgentAtOnce() {
        let status = AgentHooksRegistration.status()

        #expect(Set(status.keys) == Set(CodingAgent.allCases))
    }

    @Test func everyAgentIsListedOnce() {
        let ids = AgentHooksRegistration.agents.map(\.id)

        #expect(ids.count == CodingAgent.allCases.count)
        #expect(Set(ids).count == ids.count)
    }

    /// The name is the agent's own, from the same place the sidebar's menu
    /// takes it, so the two cannot come to call it different things.
    @Test func eachAgentIsCalledWhatTheSidebarCallsIt() {
        for agent in AgentHooksRegistration.agents {
            #expect(agent.name == agent.id.displayName, "\(agent.id.rawValue)")
        }
    }

    /// `isStale` is on this registration and not on the MCP one, and the
    /// difference is real: a hook is a generated script carrying this build's
    /// text, so it goes out of date with the app, while an entry only goes out
    /// of date when the app moves.
    @Test func everyAgentCanAnswerWhetherItsHookIsStale() {
        for agent in AgentHooksRegistration.agents {
            _ = agent.isStale()
        }
    }

    /// The one installer that used to report nothing at all when it failed.
    /// Without this, the registry would hold a `{ nil }` closure and the pane
    /// would say "install failed" with no reason for exactly one agent.
    @Test func openCodeCanReportWhyItFailed() {
        let opencode = AgentHooksRegistration.agents.first { $0.id == .opencode }

        #expect(opencode != nil)
        _ = opencode?.lastError()
    }
}
