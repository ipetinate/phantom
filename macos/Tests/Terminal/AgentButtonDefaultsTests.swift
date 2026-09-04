@testable import Ghostty
import Testing

/// Which agent buttons a fresh profile gets.
///
/// The value is one line, so what is pinned here is not arithmetic but a
/// decision: Claude Code on, the other two off until asked for. The reason to
/// test it at all is that the same fact used to be spelled out in four views
/// through `@AppStorage` fallbacks, where nothing could catch two of them
/// disagreeing — the sidebar would simply draw a button the settings pane
/// reported as off, or the reverse, depending on which view SwiftUI built
/// first.
struct AgentButtonDefaultsTests {
    @Test func onlyClaudeIsOnOutOfTheBox() {
        #expect(AgentButtonDefaults.shown == [.claude])

        #expect(AgentButtonDefaults.isShown(.claude))
        #expect(!AgentButtonDefaults.isShown(.codex))
        #expect(!AgentButtonDefaults.isShown(.opencode))
    }

    /// The surfaces read the set through the same rule a row does, so this is
    /// what a terminal row with no session actually draws on a first launch.
    @Test func aFreshTabRowDrawsClaudeAlone() {
        #expect(
            TabRowAgentActions.agents(
                shown: AgentButtonDefaults.shown, liveAgent: nil, isIdle: true
            ) == [.claude]
        )
    }

    /// Every agent stays reachable — the change is a default, not a removal, so
    /// a reader who turns Codex and OpenCode on gets all three back.
    @Test func turningTheOthersOnRestoresEveryAgent() {
        let all = Set(CodingAgent.allCases)

        #expect(AgentButtonDefaults.shown.isSubset(of: all))
        #expect(
            TabRowAgentActions.agents(shown: all, liveAgent: nil, isIdle: true)
                == CodingAgent.allCases
        )
    }
}
