import Foundation
@testable import Ghostty
import Testing

/// When the list opens, refines itself, and gets out of the way.
///
/// All of it pure, which is the point: the decision half of a popup can be
/// pinned down exhaustively here, and only the presentation half needs a
/// window — which a test host cannot show without hanging on the window
/// server.
struct CodeCompletionTriggerTests {
    private func context(
        _ line: String,
        caret: Int? = nil,
        typed: Character? = nil,
        isInStringOrComment: Bool = false,
        triggers: Set<Character> = ["."],
        minimumPrefix: Int = 1
    ) -> CodeCompletionTrigger.Context {
        CodeCompletionTrigger.Context(
            line: line,
            caretInLine: caret ?? (line as NSString).length,
            typed: typed,
            isInStringOrComment: isInStringOrComment,
            triggerCharacters: triggers,
            minimumPrefix: minimumPrefix
        )
    }

    // MARK: - The chosen behaviour

    /// The decision the user made explicitly: one character, like VS Code. A
    /// list that waits for three is a list you stop expecting.
    @Test func oneIdentifierCharacterOpensTheList() {
        let decision = CodeCompletionTrigger.decide(
            context("let c", typed: "c"),
            isListOpen: false,
            isExplicit: false
        )

        #expect(decision == .open(prefix: NSRange(location: 4, length: 1)))
    }

    @Test func furtherCharactersRefineTheOpenList() {
        let decision = CodeCompletionTrigger.decide(
            context("let co", typed: "o"),
            isListOpen: true,
            isExplicit: false
        )

        #expect(decision == .refilter(prefix: NSRange(location: 4, length: 2)))
    }

    /// The threshold is a value, not a policy baked in here — so a host that
    /// wants the old three-character behaviour gets it without touching the
    /// engine.
    @Test func aHigherThresholdDelaysTheOpenWithoutClosingAnything() {
        let shy = context("let c", typed: "c", minimumPrefix: 3)

        #expect(CodeCompletionTrigger.decide(shy, isListOpen: false, isExplicit: false) == .ignore)
        #expect(
            CodeCompletionTrigger.decide(shy, isListOpen: true, isExplicit: false)
                == .refilter(prefix: NSRange(location: 4, length: 1))
        )
    }

    /// `.ignore` rather than `.close` below the threshold, and the difference is
    /// the whole reason both cases exist: nothing was open, so nothing should be
    /// torn down. A `.close` here would be a session-ending instruction issued
    /// for a keystroke that did nothing.
    @Test func belowTheThresholdWithNoListNothingHappens() {
        #expect(
            CodeCompletionTrigger.decide(
                context("x", typed: "x", minimumPrefix: 2),
                isListOpen: false,
                isExplicit: false
            ) == .ignore
        )
    }

    // MARK: - Trigger characters

    /// The prefix after `.` is empty by definition, which is exactly the moment
    /// the list is most wanted — so the threshold cannot apply here.
    @Test func aTriggerCharacterOpensOnAnEmptyPrefix() {
        let decision = CodeCompletionTrigger.decide(
            context("foo.", typed: "."),
            isListOpen: false,
            isExplicit: false
        )

        #expect(decision == .open(prefix: NSRange(location: 4, length: 0)))
    }

    /// Trigger characters are the server's, not ours: with no server attached
    /// the set is empty, and `.` is then just punctuation.
    @Test func withNoServerADotIsOrdinaryPunctuation() {
        #expect(
            CodeCompletionTrigger.decide(
                context("foo.", typed: ".", triggers: []),
                isListOpen: true,
                isExplicit: false
            ) == .close
        )
    }

    // MARK: - Strings and comments

    /// Where a one-character trigger would otherwise be at its worst: prose is
    /// nothing but identifier characters, so every word in a comment would open
    /// a list.
    @Test func insideAStringOrCommentEveryImplicitTriggerCloses() {
        #expect(
            CodeCompletionTrigger.decide(
                context("\"abc", typed: "c", isInStringOrComment: true),
                isListOpen: true,
                isExplicit: false
            ) == .close
        )
        #expect(
            CodeCompletionTrigger.decide(
                context("\"foo.", typed: ".", isInStringOrComment: true),
                isListOpen: false,
                isExplicit: false
            ) == .close
        )
    }

    /// And the deliberate exception. Asking on purpose inside a string is a
    /// request — a path inside `import "…"`, most often — and refusing it would
    /// be the editor telling the user they did not mean it.
    @Test func explicitCompletionIgnoresTheStringSuppression() {
        let decision = CodeCompletionTrigger.decide(
            context("\"abc", isInStringOrComment: true),
            isListOpen: false,
            isExplicit: true
        )

        #expect(decision == .open(prefix: NSRange(location: 1, length: 3)))
    }

    @Test func explicitCompletionOpensOnAnEmptyPrefix() {
        let decision = CodeCompletionTrigger.decide(
            context("let "),
            isListOpen: false,
            isExplicit: true
        )

        #expect(decision == .open(prefix: NSRange(location: 4, length: 0)))
    }

    // MARK: - Everything else

    @Test func punctuationAndWhitespaceClose() {
        for character in [" ", ";", ")", "\t"] {
            #expect(
                CodeCompletionTrigger.decide(
                    context("x\(character)", typed: Character(character)),
                    isListOpen: true,
                    isExplicit: false
                ) == .close,
                "\(character.debugDescription) should close the list"
            )
        }
    }

    /// No character typed means the caret arrived some other way — an arrow key,
    /// a click, a paste. The list was built for a caret that is no longer there.
    ///
    /// Deletion is deliberately **not** one of those: backspace refines the
    /// list, and the view drives that directly rather than through `decide`.
    /// See `CodeCompletionTrigger.Context.typed`.
    @Test func aCaretThatMovedWithoutTypingCloses() {
        #expect(
            CodeCompletionTrigger.decide(
                context("let con", typed: nil),
                isListOpen: true,
                isExplicit: false
            ) == .close
        )
    }

    // MARK: - Finding the prefix

    /// `_` and `$` are identifier characters in every language here, and `$` in
    /// particular is an idiom rather than an oddity in JavaScript.
    @Test func thePrefixIncludesUnderscoresDigitsAndDollars() {
        #expect(
            CodeCompletionTrigger.prefixRange(in: context("_a1", caret: 3))
                == NSRange(location: 0, length: 3)
        )
        #expect(
            CodeCompletionTrigger.prefixRange(in: context("$el", caret: 3))
                == NSRange(location: 0, length: 3)
        )
    }

    /// The prefix is what is *behind* the caret. Completing in the middle of an
    /// existing word must not take the half in front of it, or the list would be
    /// filtered by text the user has not typed yet.
    @Test func thePrefixStopsAtTheCaret() {
        #expect(
            CodeCompletionTrigger.prefixRange(in: context("connect", caret: 3))
                == NSRange(location: 0, length: 3)
        )
    }

    @Test func aCaretAfterPunctuationHasAnEmptyPrefix() {
        #expect(
            CodeCompletionTrigger.prefixRange(in: context("foo.", caret: 4))
                == NSRange(location: 4, length: 0)
        )
    }

    /// Defensive: a caret index out of step with the line can only come from a
    /// bug elsewhere, and the answer has to be a usable range rather than a trap
    /// on a substring.
    @Test func aCaretPastTheEndOfTheLineIsClamped() {
        #expect(
            CodeCompletionTrigger.prefixRange(in: context("ab", caret: 99))
                == NSRange(location: 0, length: 2)
        )
        #expect(
            CodeCompletionTrigger.prefixRange(in: context("ab", caret: -3))
                == NSRange(location: 0, length: 0)
        )
    }

    /// The ranges are UTF-16 offsets, because that is what `NSRange` and TextKit
    /// count in — so a line with an astral-plane character in it has to come out
    /// with offsets past the surrogate pair, not past one "character".
    @Test func prefixOffsetsAreCountedInUTF16Units() {
        let line = "x = 🎉ab"

        #expect(
            CodeCompletionTrigger.prefixRange(in: context(line))
                == NSRange(location: 6, length: 2)
        )
    }
}

/// The one exception to "inside a string, everything closes".
///
/// It exists for a measured reason: the Tailwind server's own
/// `triggerCharacters` are `"`, `'`, `` ` ``, space, `-` and `:` — it expects
/// to be asked inside a string, which is the one place this trigger refused to
/// ask. What makes the exception affordable is how narrow it is, and that is
/// what most of these cases pin.
struct ClassAttributeCompletionTriggerTests {
    private func context(
        _ line: String,
        typed: Character?,
        completesClasses: Bool = true
    ) -> CodeCompletionTrigger.Context {
        CodeCompletionTrigger.Context(
            line: line,
            caretInLine: (line as NSString).length,
            typed: typed,
            /// True throughout, because it *is* true: a class attribute's
            /// value is a string literal and the highlighter says so. The
            /// exception has to survive that, or it is not an exception.
            isInStringOrComment: true,
            triggerCharacters: ["."],
            completesInsideClassAttribute: completesClasses
        )
    }

    private func decide(
        _ line: String,
        typed: Character?,
        isListOpen: Bool = false,
        completesClasses: Bool = true
    ) -> CodeCompletionTrigger.Decision {
        CodeCompletionTrigger.decide(
            context(line, typed: typed, completesClasses: completesClasses),
            isListOpen: isListOpen,
            isExplicit: false
        )
    }

    @Test func opensInsideAClassAttribute() {
        #expect(decide(#"<div className="w"#, typed: "w") == .open(prefix: NSRange(location: 16, length: 1)))
    }

    /// The keystroke that matters most and that no other rule would let
    /// through: `-` is not an identifier character and not in the trigger set.
    @Test func opensOnTheCharactersAClassIsMadeOf() {
        for typed: Character in ["-", ":", "/", "[", "!", "."] {
            let line = #"<div className="w"# + String(typed)
            #expect(decide(line, typed: typed) != .close, "typing \(typed)")
        }
    }

    /// The prefix is the class, so the filter has something to rank against.
    /// The identifier rule would report length 0 here and every candidate
    /// would score identically.
    @Test func theWholeClassIsThePrefix() {
        guard case .open(let prefix) = decide(#"<div className="w-1/"#, typed: "/") else {
            Issue.record("expected to open")
            return
        }
        #expect(prefix == NSRange(location: 16, length: 4))
    }

    @Test func spaceOpensTheNextClassOnEverything() {
        #expect(decide(#"<div className="flex "#, typed: " ") == .open(prefix: NSRange(location: 21, length: 0)))
    }

    @Test func refinesWhileTheListIsOpen() {
        let decision = decide(#"<div className="w-f"#, typed: "f", isListOpen: true)
        #expect(decision == .refilter(prefix: NSRange(location: 16, length: 3)))
    }

    /// Deletion keeps the list, which the identifier path leaves to the view.
    @Test func deletionRefinesRatherThanClosing() {
        let decision = decide(#"<div className="w-"#, typed: nil, isListOpen: true)
        #expect(decision == .refilter(prefix: NSRange(location: 16, length: 2)))
    }

    @Test func aCaretThatArrivedWithoutTypingClosesAClosedList() {
        #expect(decide(#"<div className="w-"#, typed: nil) == .close)
    }

    // MARK: - How narrow it is

    /// The rule the exception is carved out of, unchanged everywhere else.
    @Test func anOrdinaryStringStillCloses() {
        #expect(decide(#"const greeting = "hello wor"#, typed: "r") == .close)
    }

    @Test func aCommentStillCloses() {
        #expect(decide("// this is prose about wid", typed: "d") == .close)
    }

    /// No server that completes classes attached, so nothing changes at all —
    /// which is what keeps a React project with no Tailwind exactly as quiet
    /// as it was.
    @Test func withoutSuchAServerTheStringRuleIsUntouched() {
        #expect(decide(#"<div className="w"#, typed: "w", completesClasses: false) == .close)
    }

    /// Explicit still wins outright, and it wins with the *class* as its
    /// prefix — ⌃Space inside a class attribute is asking about that class.
    @Test func explicitUsesTheClassPrefixToo() {
        let decision = CodeCompletionTrigger.decide(
            context(#"<div className="w-fu"#, typed: nil),
            isListOpen: false,
            isExplicit: true
        )
        #expect(decision == .open(prefix: NSRange(location: 16, length: 4)))
    }
}
