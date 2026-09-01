import Foundation
@testable import Ghostty
import Testing

/// The eighteen keys behind the agent buttons.
///
/// These are pinned, not merely tested. Each one is a switch somebody has
/// already set, and `@AppStorage` writes whatever string it is handed: a key
/// generated one character differently is not an error anywhere — it reads as a
/// switch that will not stay on, because the write lands somewhere the reader
/// is not looking. So the assertion is the literal that was in the four views
/// before they were generated, spelled out again here.
struct AgentButtonKeyTests {
    /// The literals as the views spelled them, taken from the four
    /// declarations that used to hold them.
    private static let pinned: [AgentButtonSurface: [CodingAgent: String]] = [
        .chrome: [
            .claude: "SidebarShowClaude",
            .codex: "SidebarShowCodex",
            .opencode: "SidebarShowOpenCode",
            .antigravity: "SidebarShowAntigravity",
            .kimi: "SidebarShowKimi",
            .pi: "SidebarShowPi",
        ],
        .groupHeader: [
            .claude: "SidebarGroupShowClaude",
            .codex: "SidebarGroupShowCodex",
            .opencode: "SidebarGroupShowOpenCode",
            .antigravity: "SidebarGroupShowAntigravity",
            .kimi: "SidebarGroupShowKimi",
            .pi: "SidebarGroupShowPi",
        ],
        .tabRow: [
            .claude: "SidebarTabShowClaude",
            .codex: "SidebarTabShowCodex",
            .opencode: "SidebarTabShowOpenCode",
            .antigravity: "SidebarTabShowAntigravity",
            .kimi: "SidebarTabShowKimi",
            .pi: "SidebarTabShowPi",
        ],
    ]

    @Test func everyKeyIsTheOneAlreadyOnDisk() {
        for (surface, byAgent) in Self.pinned {
            for (agent, key) in byAgent {
                #expect(
                    AgentButtonDefaults.key(surface, agent) == key,
                    "\(surface.rawValue) \(agent.rawValue)")
            }
        }
    }

    /// The chrome keys carry no `Chrome`, unlike every other key that place
    /// owns — `SidebarChromeShowWorktree` sits beside `SidebarShowClaude`. It
    /// is pinned on its own because it is the one somebody tidying up would
    /// fix, and fixing it resets every reader's toolbar.
    @Test func theChromeKeysKeepTheirOddSpelling() {
        #expect(AgentButtonDefaults.key(.chrome, .claude) == "SidebarShowClaude")
        #expect(!AgentButtonDefaults.key(.chrome, .claude).contains("Chrome"))
    }

    /// `OpenCode` is why the agent's spelling in a key is written out rather
    /// than derived: `displayName` is "OpenCode" but Kimi's is "Kimi Code", and
    /// `rawValue.capitalized` gives "Opencode".
    @Test func theAgentSpellingIsNeitherTheNameNorTheRawValue() {
        #expect(AgentButtonDefaults.key(.tabRow, .opencode) == "SidebarTabShowOpenCode")
        #expect(AgentButtonDefaults.key(.tabRow, .kimi) == "SidebarTabShowKimi")
        #expect(CodingAgent.kimi.displayName == "Kimi Code")
    }

    /// Eighteen distinct strings. A collision would make two switches one
    /// switch, which looks like a switch that moves on its own.
    @Test func thereAreEighteenDistinctKeys() {
        var keys: [String] = []
        for surface in AgentButtonSurface.allCases {
            for agent in CodingAgent.allCases {
                keys.append(AgentButtonDefaults.key(surface, agent))
            }
        }

        #expect(keys.count == 18)
        #expect(Set(keys).count == 18)
    }

    /// Every agent and every place, so a seventh agent fails here rather than
    /// arriving with buttons nobody can switch off.
    @Test func everyAgentIsCoveredInEveryPlace() {
        for surface in AgentButtonSurface.allCases {
            for agent in CodingAgent.allCases {
                #expect(Self.pinned[surface]?[agent] != nil, "\(surface.rawValue) \(agent.rawValue)")
            }
        }
    }

    /// The default the keys are read with, which is a separate fact from the
    /// key itself and lives in the same file for that reason.
    @Test func onlyClaudeIsOnOutOfTheBox() {
        #expect(AgentButtonDefaults.isShown(.claude))
        for agent in CodingAgent.allCases where agent != .claude {
            #expect(!AgentButtonDefaults.isShown(agent), "\(agent.rawValue)")
        }
    }
}
