@testable import Ghostty
import Testing

/// Which agent buttons a tab row draws.
///
/// The rule worth pinning is the absence: these buttons type a command into a
/// shell, so a tab that already has a session must offer none. Nothing about
/// that is visible in a screenshot of a working row — it only shows up the day
/// someone clicks Codex on a tab where Claude is waiting, and reads the word
/// "codex" back as a prompt.
///
/// The second rule worth pinning is the absence of the absence. The record is
/// a file an agent's hook writes, and an agent that dies without writing its
/// last word leaves it saying `working` for the life of the tab. Every test
/// below therefore states a shell as well as a record.
struct TabRowAgentActionsTests {
    private let all: Set<CodingAgent> = [.claude, .codex, .opencode, .antigravity, .kimi, .pi]

    private let everyButton: [CodingAgent] = [
        .claude, .codex, .opencode, .antigravity, .kimi, .pi,
    ]

    @Test func aPlainTabOffersEveryAgentTheReaderEnabled() {
        #expect(
            TabRowAgentActions.agents(shown: all, liveAgent: nil, isIdle: true) == everyButton
        )

        #expect(
            TabRowAgentActions.agents(shown: [.claude, .opencode], liveAgent: nil, isIdle: true)
                == [.claude, .opencode]
        )

        #expect(TabRowAgentActions.agents(shown: [], liveAgent: nil, isIdle: true).isEmpty)
    }

    /// A tab with no record keeps its buttons whatever the foreground process
    /// is. The idle test is only ever allowed to withdraw a claim the record
    /// made, never to make one — `TerminalIdleCheck.isIdle` answers false for
    /// a pid it cannot read, and a tab that has not reported one yet is the
    /// commonest row in the sidebar.
    @Test func aTabWithNoRecordOffersTheButtonsEvenWhenBusy() {
        #expect(
            TabRowAgentActions.agents(shown: all, liveAgent: nil, isIdle: false) == everyButton
        )

        #expect(!TabRowAgentActions.hasLiveAgent(nil, isIdle: false))

        let empty = AgentTabRecord(fileContents: "")
        #expect(empty.liveAgent == nil)
        #expect(
            TabRowAgentActions.agents(
                shown: all, liveAgent: empty.liveAgent, isIdle: false
            ) == everyButton
        )
    }

    /// The one that matters: any live session, not just a matching one. A tab
    /// running Claude offers no Codex button either — the shell is busy being
    /// Claude's, whichever agent the reader picks.
    @Test func aTabWithALiveSessionOffersNone() {
        for live in CodingAgent.allCases {
            #expect(
                TabRowAgentActions.agents(shown: all, liveAgent: live, isIdle: false).isEmpty,
                "a tab running \(live.rawValue) offered a button"
            )
        }
    }

    /// An agent that has finished its turn and is waiting for the reader is
    /// still an agent, and this is the case the buttons exist to stay away
    /// from. It falls out of the same test rather than needing a rule of its
    /// own, because a waiting agent is the tab's foreground process and no
    /// agent's command is a shell name.
    @Test func aWaitingAgentIsNotAnIdleShell() {
        for agent in CodingAgent.allCases {
            #expect(
                !TerminalIdleCheck.isShell(agent.launchCommand),
                "\(agent.launchCommand) read as a shell"
            )
        }

        let waiting = AgentTabRecord(stateWord: "done", agent: .claude, sessionID: "abc")
        #expect(TabRowAgentActions.hasLiveAgent(waiting.liveAgent, isIdle: false))
        #expect(
            TabRowAgentActions.agents(
                shown: all, liveAgent: waiting.liveAgent, isIdle: false
            ).isEmpty
        )
    }

    /// The bug this rule was extended for. The reader interrupts the agent,
    /// the process goes down without reaching the exit path that writes
    /// `ended`, and the record says `working` from then on. Before the
    /// foreground process was consulted the row hid every button for good and
    /// no second agent could be started in that tab.
    @Test func aRecordStuckAtWorkingOverAShellPromptOffersTheButtonsAgain() {
        for word in ["working", "done", "awaiting", "failed", "denied", ""] {
            let stuck = AgentTabRecord(stateWord: word, agent: .opencode, sessionID: "ses_1")
            #expect(stuck.liveAgent != nil, "\"\(word)\" stopped reading as a live record")
            #expect(!TabRowAgentActions.hasLiveAgent(stuck.liveAgent, isIdle: true))
            #expect(
                TabRowAgentActions.agents(
                    shown: all, liveAgent: stuck.liveAgent, isIdle: true
                ) == everyButton,
                "a tab stuck at \"\(word)\" over a shell prompt still offered nothing"
            )
        }
    }

    /// Order comes from the enum, not from the set, so rows do not disagree
    /// with each other about where a button sits.
    @Test func theOrderIsFixedRegardlessOfTheSet() {
        let reversed: Set<CodingAgent> = [.pi, .kimi, .antigravity, .opencode, .codex, .claude]

        #expect(
            TabRowAgentActions.agents(shown: reversed, liveAgent: nil, isIdle: true)
                == TabRowAgentActions.agents(shown: all, liveAgent: nil, isIdle: true)
        )
    }

    /// The buttons come back when the reader quits the agent, which is the
    /// point of reading liveness from the record rather than from "has this tab
    /// ever run one". Both halves are checked here because the two features
    /// share the fact: a record marked as ended by the reader is also the one a
    /// restore declines to resume.
    ///
    /// Stated over a *busy* terminal on purpose. This is the path that has to
    /// keep working without any help from the foreground process, because it
    /// is the one `AgentSessionResume` reads at launch, when there is no
    /// process left to ask.
    @Test func quittingTheAgentGivesTheButtonsBack() {
        let running = AgentTabRecord(stateWord: "done", agent: .claude, sessionID: "abc")
        #expect(
            TabRowAgentActions.agents(
                shown: all, liveAgent: running.liveAgent, isIdle: false
            ).isEmpty
        )

        let quit = AgentTabRecord(
            stateWord: "ended",
            agent: .claude,
            sessionID: "abc",
            endedByUser: true
        )
        #expect(
            TabRowAgentActions.agents(
                shown: all, liveAgent: quit.liveAgent, isIdle: false
            ) == everyButton
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
