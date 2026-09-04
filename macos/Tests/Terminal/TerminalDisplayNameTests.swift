import Foundation
@testable import Ghostty
import Testing

/// One terminal is named in four places — the sidebar row, the editor's tab
/// bar, the command palette and the MCP tools — and the two rules they have
/// to keep are opposites of each other. A title the terminal reported is
/// replaced by the next one it reports; a name the reader typed is replaced by
/// nothing at all. This pins both, because the bug that motivated the type was
/// two of those four places disagreeing about which rule applied.
struct TerminalDisplayNameTests {
    // MARK: - The reader's name wins

    @Test func aCustomNameWinsOverANewTerminalTitle() {
        #expect(TerminalDisplayName.resolve(
            custom: "Eng Week | Tarefário",
            terminalTitle: "esse botao com"
        ) == "Eng Week | Tarefário")
    }

    @Test func anEmptyCustomNameDoesNotWin() {
        #expect(TerminalDisplayName.resolve(
            custom: "",
            terminalTitle: "esse botao com"
        ) == "esse botao com")
    }

    @Test func aCustomNameOfBlanksDoesNotWin() {
        #expect(TerminalDisplayName.resolve(
            custom: "   \n",
            terminalTitle: "esse botao com"
        ) == "esse botao com")
    }

    @Test func aMissingCustomNameDoesNotWin() {
        #expect(TerminalDisplayName.resolve(
            custom: nil,
            terminalTitle: "esse botao com"
        ) == "esse botao com")
    }

    // MARK: - The terminal's own title is replaced

    @Test func aTerminalTitleReplacesThePreviousTerminalTitle() {
        let before = TerminalDisplayName.resolve(
            custom: nil,
            terminalTitle: "esse botao com"
        )
        let after = TerminalDisplayName.resolve(
            custom: nil,
            terminalTitle: "Refatorar o tab bar"
        )
        #expect(before == "esse botao com")
        #expect(after == "Refatorar o tab bar")
    }

    @Test func aCustomNameSurvivesEveryTitleAfterIt() {
        for title in ["esse botao com", "Refatorar o tab bar", "", "~/phantom"] {
            #expect(TerminalDisplayName.resolve(
                custom: "Eng Week",
                terminalTitle: title
            ) == "Eng Week")
        }
    }

    // MARK: - Something to draw

    @Test func aTerminalWithNoTitleAtAllStillHasSomethingToDraw() {
        #expect(TerminalDisplayName.resolve(custom: nil, terminalTitle: nil) == "Terminal")
        #expect(TerminalDisplayName.resolve(custom: "", terminalTitle: "") == "Terminal")
        #expect(TerminalDisplayName.resolve(custom: " ", terminalTitle: " \t") == "Terminal")
    }

    @Test func aCallerCanSayWhatNothingIsCalled() {
        #expect(TerminalDisplayName.resolve(
            custom: nil,
            terminalTitle: nil,
            fallback: "phantom"
        ) == "phantom")
    }

    @Test func nothingToDrawIsNilForTheCallersThatDrawNothing() {
        #expect(TerminalDisplayName.name(custom: nil, terminalTitle: nil) == nil)
        #expect(TerminalDisplayName.name(custom: "  ", terminalTitle: "") == nil)
        #expect(TerminalDisplayName.name(custom: nil, terminalTitle: "esse botao com")
            == "esse botao com")
    }

    // MARK: - What is drawn is trimmed

    @Test func aNameIsDrawnWithoutTheBlanksAroundIt() {
        #expect(TerminalDisplayName.resolve(
            custom: "  Eng Week  ",
            terminalTitle: nil
        ) == "Eng Week")
        #expect(TerminalDisplayName.resolve(
            custom: nil,
            terminalTitle: "\tesse botao com\n"
        ) == "esse botao com")
    }
}
