@testable import Ghostty
import Testing

struct CodingAgentTests {
    private static let pinned: [(CodingAgent, String)] = [
        (.claude, "claude"),
        (.codex, "codex"),
        (.cursor, "cursor"),
        (.opencode, "opencode"),
        (.antigravity, "antigravity"),
        (.kimi, "kimi"),
        (.pi, "pi"),
        (.goose, "goose"),
        (.kilo, "kilo"),
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
        #expect(CodingAgent.allCases == [
            .claude, .codex, .cursor, .opencode, .antigravity, .kimi, .pi, .goose, .kilo,
        ])
    }

    @Test func twoValuesWithOneIdAreOneAgent() {
        let fromDisk = CodingAgent(rawValue: "codex")

        #expect(fromDisk == .codex)
        #expect(fromDisk?.hashValue == CodingAgent.codex.hashValue)
        #expect(Set([CodingAgent.codex, fromDisk].compactMap { $0 }).count == 1)
    }

    @Test func theSpellingsComeFromTheDescriptor() {
        #expect(CodingAgent.claude.displayName == "Claude Code")
        #expect(CodingAgent.codex.displayName == "Codex")
        #expect(CodingAgent.cursor.displayName == "Cursor")
        #expect(CodingAgent.opencode.displayName == "OpenCode")
        #expect(CodingAgent.antigravity.displayName == "Antigravity")
        #expect(CodingAgent.kimi.displayName == "Kimi Code")
        #expect(CodingAgent.pi.displayName == "Pi")
        #expect(CodingAgent.goose.displayName == "Goose")
        #expect(CodingAgent.kilo.displayName == "Kilo Code")

        #expect(CodingAgent.claude.launchCommand == "claude")
        #expect(CodingAgent.codex.launchCommand == "codex")
        #expect(CodingAgent.cursor.launchCommand == "cursor-agent")
        #expect(CodingAgent.opencode.launchCommand == "opencode")
        #expect(CodingAgent.antigravity.launchCommand == "agy")
        #expect(CodingAgent.kimi.launchCommand == "kimi")
        #expect(CodingAgent.pi.launchCommand == "pi")
        #expect(CodingAgent.goose.launchCommand == "goose")
        #expect(CodingAgent.kilo.launchCommand == "kilo")

        #expect(CodingAgent.claude.resumeCommand(sessionID: "abc") == "claude --resume abc")
        #expect(CodingAgent.codex.resumeCommand(sessionID: "abc") == "codex resume abc")
        #expect(CodingAgent.cursor.resumeCommand(sessionID: "abc") == "cursor-agent --resume abc")
        #expect(CodingAgent.opencode.resumeCommand(sessionID: "abc") == "opencode --session abc")
        #expect(CodingAgent.antigravity.resumeCommand(sessionID: "abc") == "agy --conversation abc")
        #expect(CodingAgent.kimi.resumeCommand(sessionID: "abc") == "kimi --session abc")
        #expect(CodingAgent.pi.resumeCommand(sessionID: "abc") == "pi --session abc")
        #expect(CodingAgent.goose.resumeCommand(sessionID: "abc") == "goose session --resume")
        #expect(CodingAgent.kilo.resumeCommand(sessionID: "abc") == "kilo --session abc")
    }

    @Test func everyAgentHasADescriptorOfItsOwn() {
        for agent in CodingAgent.allCases {
            #expect(agent.descriptor.id == agent.rawValue)
            #expect(agent.descriptor == AgentRegistry.shared.descriptor(for: agent.rawValue))
        }
    }
}
