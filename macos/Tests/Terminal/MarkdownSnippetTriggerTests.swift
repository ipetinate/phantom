@testable import Ghostty
import Testing

/// That a bare `/` is enough to open the snippet list.
///
/// The catalogue answered when asked from the first day it existed, and
/// nothing asked: `CodeCompletionTrigger.decide` opens the list on a *trigger
/// character* or on an identifier, and a slash is neither. So the rows only
/// appeared once a letter had followed the slash — which makes a catalogue
/// meant for browsing into one you have to know by heart.
struct MarkdownSnippetTriggerTests {
    private func decision(typed: Character, triggers: Set<Character>) -> CodeCompletionTrigger.Decision {
        CodeCompletionTrigger.decide(
            CodeCompletionTrigger.Context(
                line: "a line ending in \(typed)",
                caretInLine: ("a line ending in \(typed)" as NSString).length,
                typed: typed,
                isInStringOrComment: false,
                triggerCharacters: triggers
            ),
            isListOpen: false,
            isExplicit: false
        )
    }

    /// The bug, stated: without the slash among the triggers, typing one
    /// closes the list rather than opening it.
    @Test func aSlashDoesNothingUnlessItIsATrigger() {
        #expect(decision(typed: "/", triggers: ["."]) == .close)
    }

    @Test func aSlashOpensTheListWhenItIsATrigger() {
        guard case .open = decision(typed: "/", triggers: [".", "/"]) else {
            Issue.record("a slash should open the list")
            return
        }
    }

    /// The dot has to survive being joined by the slash — a Markdown file in a
    /// TypeScript project still has a language server, and trading one trigger
    /// for another would be trading one feature for another.
    @Test func theDotStillOpensTheListWhenTheSlashIsAdded() {
        guard case .open = decision(typed: ".", triggers: [".", "/"]) else {
            Issue.record("the dot should still open the list")
            return
        }
    }
}
