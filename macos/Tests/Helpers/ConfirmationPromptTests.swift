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
}
