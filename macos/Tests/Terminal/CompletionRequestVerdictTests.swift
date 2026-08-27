@testable import Ghostty
import Testing

/// Whether a keystroke asks for completions, and what happens when it does
/// not.
///
/// Two switches govern this and they are not the same switch, which is the
/// whole of what is asserted here.
///
/// **Suggest Completions** is the master. Settings promises, in as many
/// words, that with it off "nothing opens the list — not a trigger character,
/// not an explicit request", so ⌃Space does not overrule it.
///
/// **Suggest completions while typing** covers only the list that arrives
/// unasked. Off, nothing opens by itself and ⌃Space still works.
///
/// The third answer — say so — exists because an explicit ask that produces
/// nothing and says nothing is indistinguishable from a key that is not
/// bound, and that ambiguity is the report this path came from.
@MainActor
struct CompletionRequestVerdictTests {
    private func verdict(
        explicit: Bool,
        enabled: Bool = true,
        whileTyping: Bool = true,
        provider: Bool = true
    ) -> CodeNSTextView.CompletionRequestVerdict {
        CodeNSTextView.completionRequestVerdict(
            isExplicit: explicit,
            completionEnabled: enabled,
            suggestsWhileTyping: whileTyping,
            hasProvider: provider
        )
    }

    // MARK: The ordinary case

    @Test func typingAsksWhenBothSwitchesAreOn() {
        #expect(verdict(explicit: false) == .ask)
    }

    @Test func anExplicitRequestAsks() {
        #expect(verdict(explicit: true) == .ask)
    }

    // MARK: Suggest while typing

    /// The setting's own promise, and the reason ⌃Space has to keep working:
    /// off is about the unasked list, not about completion.
    @Test func withSuggestionsOffTypingIsQuietAndControlSpaceStillWorks() {
        #expect(verdict(explicit: false, whileTyping: false) == .stayQuiet)
        #expect(verdict(explicit: true, whileTyping: false) == .ask)
    }

    /// Silent, not announced. A list that never opened is the normal outcome
    /// of most characters typed, and a notice per keystroke would be worse
    /// than the feature being off.
    @Test func aSuppressedKeystrokeSaysNothing() {
        #expect(verdict(explicit: false, whileTyping: false) != .sayItIsOff)
    }

    // MARK: The master switch

    @Test func theOverridingSwitchOutranksTheExplicitRequest() {
        #expect(verdict(explicit: true, enabled: false) == .sayItIsOff)
        #expect(verdict(explicit: true, enabled: false) != .ask)
    }

    @Test func theOverridingSwitchAlsoStopsTyping() {
        #expect(verdict(explicit: false, enabled: false) == .stayQuiet)
    }

    /// Off overrides on: the narrower switch cannot bring back what the
    /// master turned off.
    @Test func theOverridingSwitchWinsWhateverTheOtherSays() {
        #expect(verdict(explicit: true, enabled: false, whileTyping: true) == .sayItIsOff)
        #expect(verdict(explicit: false, enabled: false, whileTyping: true) == .stayQuiet)
    }

    // MARK: No producer

    /// A view with nothing to ask is quiet either way. It is not the reader's
    /// setting that is missing, so telling them completions are off would be
    /// a lie.
    @Test func aViewWithNoProviderIsQuiet() {
        #expect(verdict(explicit: true, provider: false) == .stayQuiet)
        #expect(verdict(explicit: false, provider: false) == .stayQuiet)
    }

    /// And the order matters: a reader who switched completion off and has no
    /// server attached is told about the switch, because the switch is the
    /// thing they can do something about.
    @Test func theSwitchIsReportedBeforeTheMissingProvider() {
        #expect(verdict(explicit: true, enabled: false, provider: false) == .sayItIsOff)
    }
}
