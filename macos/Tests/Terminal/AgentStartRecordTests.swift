import Foundation
@testable import Ghostty
import Testing

/// Recording which agent a tab was started with, before that agent has said
/// anything.
///
/// The gap these cover: whether a tab had an agent in it was known only from
/// a file the *hook* writes, so a tab whose hook was not installed — or whose
/// agent exited before reaching a hook event — left nothing behind, and a
/// restore had no reason to believe there had ever been a session there. It
/// did not fail to resume; it never tried.
struct AgentStartRecordTests {
    /// The record a start writes, and what a restore would make of it.
    private func resumeCommand(afterStarting agent: CodingAgent) -> String? {
        let record = AgentTabRecord(stateWord: "", agent: agent)
        return AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents)
    }

    @Test func aStartedAgentIsResumableWithNoHookInvolved() throws {
        #expect(resumeCommand(afterStarting: .claude) == "claude --continue")
        #expect(resumeCommand(afterStarting: .codex) == "codex resume --last")
        #expect(resumeCommand(afterStarting: .opencode) == "opencode --continue")
    }

    /// Once a hook does supply an id, the resume becomes the precise one —
    /// which is the whole point of capturing ids.
    @Test func anIdUpgradesTheResumeToThatExactSession() {
        let record = AgentTabRecord(
            stateWord: "working",
            agent: .claude,
            sessionID: "9f8e7d6c-1234-4567-89ab-cdef01234567"
        )
        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents)
                == "claude --resume 9f8e7d6c-1234-4567-89ab-cdef01234567"
        )
    }

    /// Every agent's start record round-trips through the file format, so the
    /// agent a tab was started with is still known after a quit.
    @Test func theAgentSurvivesTheFileFormat() throws {
        for agent in [CodingAgent.claude, .codex, .opencode] {
            let written = AgentTabRecord(stateWord: "", agent: agent).fileContents
            let parsed = AgentTabRecord(fileContents: written)
            #expect(parsed.agent == agent, "\(agent.rawValue) did not survive")
            #expect(parsed.carriesIdentity)
        }
    }

    /// A start record shows no indicator: it says which agent the tab runs,
    /// not what that agent is doing.
    @Test func aStartRecordCarriesNoState() {
        let parsed = AgentTabRecord(
            fileContents: AgentTabRecord(stateWord: "", agent: .codex).fileContents
        )
        #expect(parsed.state == nil)
        #expect(parsed.stateWord.isEmpty)
    }

    /// A session the reader ended on purpose stays ended — a start record
    /// must not resurrect it.
    @Test func anEndedSessionIsStillNotResumed() {
        let record = AgentTabRecord(stateWord: "ended", agent: .claude, sessionID: "abc123")
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents) == nil)
    }

    /// The command that starts an agent and the one that resumes it come from
    /// the same case, so they cannot drift apart.
    @Test func launchAndResumeAgreeOnTheAgent() {
        #expect(CodingAgent.claude.launchCommand == "claude")
        #expect(CodingAgent.codex.launchCommand == "codex")
        #expect(CodingAgent.opencode.launchCommand == "opencode")
    }
}
