@testable import Ghostty
import Testing

/// The six ids, pinned as the strings that are already on disk.
///
/// A raw value is written into every tab-state file as `agent=<id>` and into
/// every chosen icon as `agent:<id>`, so it outlives any one build. The agent
/// is a value keyed by that id now rather than an enum case, and nothing about
/// the change may move a single byte of it.
struct CodingAgentTests {
    private static let pinned: [(CodingAgent, String)] = [
        (.claude, "claude"),
        (.codex, "codex"),
        (.opencode, "opencode"),
        (.antigravity, "antigravity"),
        (.kimi, "kimi"),
        (.pi, "pi"),
    ]

    @Test func everyRawValueIsTheOneAlreadyOnDisk() {
        for (agent, id) in Self.pinned {
            #expect(agent.rawValue == id)
            #expect(CodingAgent(rawValue: id) == agent)
        }
    }

    @Test func aPersistedAgentLineStillParses() {
        for (agent, id) in Self.pinned {
            let record = AgentTabRecord(fileContents: "working\nagent=\(id)\nsession=abc\n")
            #expect(record.agent == agent, Comment(rawValue: id))
            #expect(record.fileContents == "working\nagent=\(id)\nsession=abc\n")
        }
    }

    @Test func anUnknownIdIsNotAnAgent() {
        #expect(CodingAgent(rawValue: "aider") == nil)
        #expect(CodingAgent(rawValue: "Claude") == nil)
        #expect(CodingAgent(rawValue: "") == nil)
        #expect(AgentTabRecord(fileContents: "working\nagent=aider\n").agent == nil)
    }

    @Test func allCasesFollowsTheRegistryOrder() {
        #expect(CodingAgent.allCases.map(\.rawValue) == AgentRegistry.shared.all.map(\.id))
        #expect(CodingAgent.allCases == [.claude, .codex, .opencode, .antigravity, .kimi, .pi])
    }

    @Test func twoValuesWithOneIdAreOneAgent() {
        let fromDisk = CodingAgent(rawValue: "codex")

        #expect(fromDisk == .codex)
        #expect(fromDisk.hashValue == CodingAgent.codex.hashValue)
        #expect(Set([CodingAgent.codex, fromDisk].compactMap { $0 }).count == 1)
    }

    @Test func theSpellingsComeFromTheDescriptor() {
        #expect(CodingAgent.claude.displayName == "Claude Code")
        #expect(CodingAgent.codex.displayName == "Codex")
        #expect(CodingAgent.opencode.displayName == "OpenCode")
        #expect(CodingAgent.antigravity.displayName == "Antigravity")
        #expect(CodingAgent.kimi.displayName == "Kimi Code")
        #expect(CodingAgent.pi.displayName == "Pi")

        #expect(CodingAgent.claude.launchCommand == "claude")
        #expect(CodingAgent.codex.launchCommand == "codex")
        #expect(CodingAgent.opencode.launchCommand == "opencode")
        #expect(CodingAgent.antigravity.launchCommand == "agy")
        #expect(CodingAgent.kimi.launchCommand == "kimi")
        #expect(CodingAgent.pi.launchCommand == "pi")

        #expect(CodingAgent.claude.resumeCommand(sessionID: "abc") == "claude --resume abc")
        #expect(CodingAgent.codex.resumeCommand(sessionID: "abc") == "codex resume abc")
        #expect(CodingAgent.opencode.resumeCommand(sessionID: "abc") == "opencode --session abc")
        #expect(CodingAgent.antigravity.resumeCommand(sessionID: "abc") == "agy --conversation abc")
        #expect(CodingAgent.kimi.resumeCommand(sessionID: "abc") == "kimi --session abc")
        #expect(CodingAgent.pi.resumeCommand(sessionID: "abc") == "pi --session abc")
    }

    @Test func everyAgentHasADescriptorOfItsOwn() {
        for agent in CodingAgent.allCases {
            #expect(agent.descriptor.id == agent.rawValue)
            #expect(agent.descriptor == AgentRegistry.shared.descriptor(for: agent.rawValue))
        }
    }
}
