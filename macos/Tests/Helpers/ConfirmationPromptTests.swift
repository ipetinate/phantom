import Foundation
@testable import Ghostty
import Testing

struct ConfirmationPromptTests {
    private func prompt(details: [ConfirmationPrompt.Detail]) -> ConfirmationPrompt {
        ConfirmationPrompt(
            title: "Run a Language Server from “Lua”?",
            consequence: "It runs as you.",
            details: details,
            primary: .init(title: "Run Language Server"),
            secondary: .init(title: "Don't Run", isDefault: true)
        )
    }

    @Test func theDetailTextJoinsTheRowsInOrder() {
        let text = prompt(details: [
            .init(label: "Publisher", value: "Acme"),
            .init(label: "Command", value: "lua-language-server --stdio"),
            .init(label: "Resolves to", value: "/opt/homebrew/bin/lua-language-server"),
        ]).detailText

        #expect(text == """
        Publisher: Acme
        Command: lua-language-server --stdio
        Resolves to: /opt/homebrew/bin/lua-language-server
        """)
    }

    @Test func noDetailsIsNoText() {
        #expect(prompt(details: []).detailText.isEmpty)
    }

    @Test func theTrustPromptDefaultsToRefusing() {
        let request = LanguageTrustAlert.Request(
            extensionName: "Lua",
            extensionID: "acme.lua",
            publisher: "Acme",
            extensionVersion: "1.0.0",
            languageName: "Lua",
            command: "lua-language-server",
            arguments: ["--stdio"],
            resolvedPath: "/opt/homebrew/bin/lua-language-server",
            manifestPath: "/Users/x/.config/phantom/extensions/acme.lua/extension.json",
            change: .firstRun
        )

        let prompt = LanguageTrustAlert.prompt(for: request)

        #expect(prompt.secondary == .init(title: "Don't Run", isDefault: true))
        #expect(prompt.primary == .init(title: "Run Language Server"))
        #expect(prompt.change == nil)
        #expect(prompt.details.map(\.label) == [
            "Publisher", "Command", "Resolves to", "Manifest", "Extension", "Version",
        ])
        #expect(prompt.detailText.contains("Command: lua-language-server --stdio"))
        #expect(LanguageTrustAlert.informativeText(for: request) == [
            prompt.consequence, prompt.remember,
        ].compactMap { $0 }.joined(separator: "\n\n"))
    }
}
