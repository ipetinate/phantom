@testable import Ghostty
import Testing

/// Which agent buttons a tab row draws.
///
/// The rule worth pinning is the absence: these buttons type a command into a
/// shell, so a tab that already has a session must offer none. Nothing about
/// that is visible in a screenshot of a working row — it only shows up the day
/// someone clicks Codex on a tab where Claude is waiting, and reads the word
/// "codex" back as a prompt.
struct TabRowAgentActionsTests {
    private let all: Set<CodingAgent> = [.claude, .codex, .opencode]

    @Test func aPlainTabOffersEveryAgentTheReaderEnabled() {
        #expect(
            TabRowAgentActions.agents(shown: all, liveAgent: nil)
                == [.claude, .codex, .opencode]
        )

        #expect(
            TabRowAgentActions.agents(shown: [.claude, .opencode], liveAgent: nil)
                == [.claude, .opencode]
        )

        #expect(TabRowAgentActions.agents(shown: [], liveAgent: nil).isEmpty)
    }

    /// The one that matters: any live session, not just a matching one. A tab
    /// running Claude offers no Codex button either — the shell is busy being
    /// Claude's, whichever agent the reader picks.
    @Test func aTabWithALiveSessionOffersNone() {
        for live in CodingAgent.allCases {
            #expect(
                TabRowAgentActions.agents(shown: all, liveAgent: live).isEmpty,
                "a tab running \(live.rawValue) offered a button"
            )
        }
    }

    /// Order comes from the enum, not from the set, so rows do not disagree
    /// with each other about where a button sits.
    @Test func theOrderIsFixedRegardlessOfTheSet() {
        let reversed: Set<CodingAgent> = [.opencode, .codex, .claude]

        #expect(
            TabRowAgentActions.agents(shown: reversed, liveAgent: nil)
                == TabRowAgentActions.agents(shown: all, liveAgent: nil)
        )
    }

    /// The buttons come back when the reader quits the agent, which is the
    /// point of reading liveness from the record rather than from "has this tab
    /// ever run one". Both halves are checked here because the two features
    /// share the fact: a record marked as ended by the reader is also the one a
    /// restore declines to resume.
    @Test func quittingTheAgentGivesTheButtonsBack() {
        let running = AgentTabRecord(stateWord: "done", agent: .claude, sessionID: "abc")
        #expect(TabRowAgentActions.agents(shown: all, liveAgent: running.liveAgent).isEmpty)

        let quit = AgentTabRecord(
            stateWord: "ended",
            agent: .claude,
            sessionID: "abc",
            endedByUser: true
        )
        #expect(
            TabRowAgentActions.agents(shown: all, liveAgent: quit.liveAgent)
                == [.claude, .codex, .opencode]
        )
    }

    /// Every agent has to be nameable, since the button's tooltip is built from
    /// it and an empty one would read as a bug in the row.
    @Test func everyAgentHasAName() {
        for agent in CodingAgent.allCases {
            #expect(!agent.displayName.isEmpty)
            #expect(!agent.launchCommand.isEmpty)
        }
    }
}
