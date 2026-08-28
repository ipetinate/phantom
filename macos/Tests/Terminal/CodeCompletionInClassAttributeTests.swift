import AppKit
@testable import Ghostty
import Testing

/// Whether typing inside a `class` attribute actually reaches the completion
/// provider — the whole point of the class-attribute exception, and the one
/// step `CodeCompletionTriggerTests` cannot see.
///
/// That file tests the *decision* as a pure function, which is right and is
/// not enough: the decision has to be reached with the flag set, the keystroke
/// has to arrive through `insertText`, and the answer to `.open` has to be an
/// actual request. Between the rule and the request sit the four early returns
/// in the auto-closing path, the debounce, and a flag the host supplies — and
/// a break in any of them is invisible to a test of `decide`.
///
/// **The provider always answers `.unchanged`**, which is what keeps this
/// suite safe to run. `requestCompletions` guards on `case .items` before
/// calling `showCompletions`, and only `showCompletions` reaches
/// `CodeCompletionPanel.present` and through it `orderFront` — a call that
/// never returns in a host with no running event loop. Answering `.unchanged`
/// observes everything up to that line and stops there, the same bargain
/// `CodeHoverPersistenceTests` strikes with its empty `CodeHoverInfo`.
@MainActor
struct CodeCompletionInClassAttributeTests {
    /// Records what the engine asked for, and when it did not ask.
    private final class Provider {
        var offsets: [Int] = []
    }

    /// A real, never-shown window — enough for TextKit to lay out glyphs
    /// without putting anything on the developer's display.
    ///
    /// The four substitution switches are copied from `makeNSView` and are
    /// **not** decoration here. AppKit's automatic quote substitution is on by
    /// default on a bare `NSTextView`, and it rewrites the straight quotes
    /// around the caret into curly ones as soon as anything is typed between
    /// them. `CodeClassAttribute` looks for `"`, `'` and `` ` `` and knows
    /// nothing about `“` — so a harness missing these lines reports that
    /// completion inside `className` is dead, in an app where it is not.
    private func makeTextView(
        text: String,
        caret: Int,
        completesInsideClassAttribute: Bool
    ) -> (window: NSWindow, textView: CodeNSTextView, provider: Provider) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let textView = CodeNSTextView(frame: frame)
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        textView.completionEnabled = true
        textView.completesInsideClassAttribute = completesInsideClassAttribute
        textView.completionTriggers = ["."]
        textView.hoverLanguage = .javascript
        textView.completionFetchDelay = .milliseconds(1)
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        let provider = Provider()
        textView.completionProvider = { request in
            await MainActor.run { provider.offsets.append(request.offset) }
            return .unchanged // see the type comment — never reaches orderFront
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = textView
        return (window, textView, provider)
    }

    private func type(_ characters: String, into textView: CodeNSTextView) {
        for character in characters {
            textView.insertText(
                String(character),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
    }

    /// Comfortably past the 1ms fetch delay set above, with room for the hop
    /// onto the main actor and back.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The control. Without it a green suite could mean "the harness never
    /// asks for anything" rather than "the exception works".
    @Test func anOrdinaryIdentifierAsksTheProvider() async {
        let (window, textView, provider) = makeTextView(
            text: "const value = 1\nva",
            caret: 18,
            completesInsideClassAttribute: false
        )
        defer { window.contentView = nil }

        type("l", into: textView)
        await settle()

        #expect(provider.offsets.count == 1, "\(provider.offsets)")
    }

    /// The reported bug, at the layer it is decided: typing inside
    /// `className=""` must ask, even though a class attribute's value is a
    /// string literal and the string suppression would otherwise close the
    /// list on exactly these keystrokes.
    @Test func typingInsideAClassAttributeAsksTheProvider() async {
        let (window, textView, provider) = makeTextView(
            text: #"<div className="">"#,
            caret: 16,
            completesInsideClassAttribute: true
        )
        defer { window.contentView = nil }

        type("fl", into: textView)
        await settle()

        #expect(provider.offsets.isEmpty == false, "\(provider.offsets)")
        #expect(textView.string == #"<div className="fl">"#, "\(textView.string)")
    }

    /// `-` is neither an identifier character nor one of the trigger
    /// characters, so nothing but the class-attribute rule lets it through —
    /// and half of Tailwind's vocabulary is on the far side of a dash.
    @Test func aDashInsideAClassAttributeAsksTheProvider() async {
        let (window, textView, provider) = makeTextView(
            text: #"<div className="w">"#,
            caret: 17,
            completesInsideClassAttribute: true
        )
        defer { window.contentView = nil }

        type("-", into: textView)
        await settle()

        #expect(provider.offsets.isEmpty == false, "\(provider.offsets)")
    }

    /// A space starts the next class with an empty prefix, which is the whole
    /// list again — the moment a reader adds a second utility.
    @Test func aSpaceInsideAClassAttributeAsksTheProvider() async {
        let (window, textView, provider) = makeTextView(
            text: #"<div className="flex ">"#,
            caret: 21,
            completesInsideClassAttribute: true
        )
        defer { window.contentView = nil }

        type(" ", into: textView)
        await settle()

        #expect(provider.offsets.isEmpty == false, "\(provider.offsets)")
    }

    /// The other half of the contract, and the reason the flag exists rather
    /// than the rule being unconditional: with no server attached that
    /// completes inside a class attribute, these keystrokes are ordinary text
    /// inside an ordinary string and must stay quiet.
    @Test func theSameKeystrokesAskNothingWhenNoServerCompletesClasses() async {
        let (window, textView, provider) = makeTextView(
            text: #"<div className="">"#,
            caret: 16,
            completesInsideClassAttribute: false
        )
        defer { window.contentView = nil }

        type("fl", into: textView)
        await settle()

        #expect(provider.offsets.isEmpty, "\(provider.offsets)")
    }

    /// The rule the exception is carved out of, unchanged: an ordinary string
    /// literal still suppresses the list even with the flag on, because the
    /// attribute name is what the exception is keyed on and `greeting` is not
    /// one.
    ///
    /// **The literal is closed on purpose.** The suppression is the
    /// highlighter's answer, and its string pattern needs a closing quote —
    /// measured, the same line without one yields no string token, the
    /// identifier rule applies, and the list opens. That is existing
    /// behaviour and arguably the right one while a line is half-typed; it is
    /// noted here so the next person to write this test does not assert the
    /// opposite and conclude the exception is leaking.
    @Test func anOrdinaryStringStillAsksNothing() async {
        let (window, textView, provider) = makeTextView(
            text: #"const greeting = "hello wor""#,
            caret: 27,
            completesInsideClassAttribute: true
        )
        defer { window.contentView = nil }

        type("r", into: textView)
        await settle()

        #expect(provider.offsets.isEmpty, "\(provider.offsets)")
    }
}
