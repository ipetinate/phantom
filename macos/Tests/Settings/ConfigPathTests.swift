import Foundation
@testable import Ghostty
import Testing

struct ConfigPathTests {
    private let home = URL(fileURLWithPath: "/Users/reader", isDirectory: true)

    private func resolve(
        _ path: ConfigPath,
        environment: [String: String] = [:],
        existing: Set<String> = []
    ) -> String {
        path.resolve(environment: environment, home: home, exists: existing.contains).path
    }

    @Test func aTildeExpandsToTheHomeDirectory() {
        #expect(resolve("~/.claude") == "/Users/reader/.claude")
        #expect(resolve("~") == "/Users/reader")
        #expect(resolve("~/.gemini/config") == "/Users/reader/.gemini/config")
    }

    @Test func anAbsolutePathIsTakenAsWritten() {
        #expect(resolve("/etc/phantom") == "/etc/phantom")
    }

    @Test func aSetVariableWinsWhetherOrNotItExistsOnDisk() {
        let codex = AgentRegistry.codexHome

        #expect(resolve(codex, environment: ["CODEX_HOME": "/srv/codex"]) == "/srv/codex")
        #expect(
            resolve(codex, environment: ["CODEX_HOME": "/srv/codex"], existing: ["/Users/reader/.codex-cli"])
                == "/srv/codex")
    }

    @Test func anUnsetOrEmptyVariableIsSkipped() {
        let codex = AgentRegistry.codexHome

        #expect(resolve(codex) == "/Users/reader/.codex")
        #expect(resolve(codex, environment: ["CODEX_HOME": ""]) == "/Users/reader/.codex")
    }

    @Test func anIntermediateCandidateIsTakenOnlyWhenItExists() {
        let codex = AgentRegistry.codexHome

        #expect(resolve(codex, existing: ["/Users/reader/.codex-cli"]) == "/Users/reader/.codex-cli")
        #expect(resolve(codex, existing: ["/Users/reader/.codex"]) == "/Users/reader/.codex")
    }

    @Test func theLastCandidateIsTheDefaultWhetherOrNotItExists() {
        #expect(resolve(AgentRegistry.kimiHome) == "/Users/reader/.kimi-code")
        #expect(
            resolve(AgentRegistry.kimiHome, environment: ["KIMI_CODE_HOME": "/opt/kimi"])
                == "/opt/kimi")
    }

    @Test func aVariableMayCarryAPathAfterIt() {
        let path = ConfigPath(["$XDG_DATA_HOME/opencode", "~/.local/share/opencode"])

        #expect(resolve(path, environment: ["XDG_DATA_HOME": "/data"]) == "/data/opencode")
        #expect(resolve(path) == "/Users/reader/.local/share/opencode")
    }

    @Test func expansionReportsAnUnsetVariableAsNil() {
        #expect(ConfigPath.expand("$NOPE", environment: [:], home: home) == nil)
        #expect(ConfigPath.expand("$NOPE/x", environment: ["NOPE": ""], home: home) == nil)
        #expect(ConfigPath.expand("$HOME_DIR", environment: ["HOME_DIR": "/h"], home: home) == "/h")
    }

    @Test func aStringLiteralIsOneCandidate() {
        let path: ConfigPath = "~/.pi/agent"
        #expect(path.candidates == ["~/.pi/agent"])
    }
}
