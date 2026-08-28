import AppKit
@testable import Ghostty
import Testing

/// Which command a key press is, for the two keys that ask the editor for
/// help — ⌃Space and ⌃.
///
/// Written because the report was "⌃Space does nothing", and because the
/// branch it replaced could not have done anything: it compared the whole
/// modifier mask against `.control`, which fails whenever caps lock is down,
/// and it compared `charactersIgnoringModifiers` against a space, which ⌃Space
/// does not always report. Both are asserted here so neither can come back.
@MainActor
struct EditorAssistShortcutTests {
    /// Space is `kVK_Space`; the full stop is `kVK_ANSI_Period`.
    private static let spaceKey: UInt16 = 49
    private static let periodKey: UInt16 = 47

    private func press(
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func command(_ event: NSEvent, host: [String: [EditorShortcut]] = [:]) -> String? {
        CodeNSTextView.assistCommand(for: event, host: host)
    }

    // MARK: The two keys

    @Test func controlSpaceAsksForSuggestions() {
        #expect(
            command(press(" ", .control, keyCode: Self.spaceKey))
                == EditorAssistCommand.triggerSuggest.actionID
        )
    }

    @Test func controlPeriodAsksForFixes() {
        #expect(
            command(press(".", .control, keyCode: Self.periodKey))
                == EditorAssistCommand.quickFix.actionID
        )
    }

    // MARK: The two faults that made ⌃Space silent

    /// ⌃Space reports the control character it *sends* rather than the key it
    /// was pressed on, on layouts where `charactersIgnoringModifiers` is
    /// filled in from the sent text. A comparison against `" "` never matched,
    /// and the key did nothing, on those machines only — which is exactly the
    /// shape of a bug that survives being tried on somebody else's Mac.
    @Test func aSpaceReportedAsNulStillCounts() {
        #expect(
            command(press("\u{0}", .control, keyCode: Self.spaceKey))
                == EditorAssistCommand.triggerSuggest.actionID
        )
    }

    @Test func aSpaceReportedAsNothingStillCounts() {
        #expect(
            command(press("", .control, keyCode: Self.spaceKey))
                == EditorAssistCommand.triggerSuggest.actionID
        )
    }

    /// Caps lock is a modifier flag like any other, and the old equality
    /// against the whole mask failed on every press made with it down.
    @Test func capsLockDoesNotBreakEitherKey() {
        #expect(
            command(press(" ", [.control, .capsLock], keyCode: Self.spaceKey))
                == EditorAssistCommand.triggerSuggest.actionID
        )
        #expect(
            command(press(".", [.control, .capsLock], keyCode: Self.periodKey))
                == EditorAssistCommand.quickFix.actionID
        )
    }

    // MARK: What it must not claim

    /// The space bar is how text is typed. A binding that answered a bare
    /// space would be an editor that cannot type.
    @Test func aBareSpaceIsNotACommand() {
        #expect(command(press(" ", [], keyCode: Self.spaceKey)) == nil)
    }

    @Test func aDifferentModifierIsNotThisCommand() {
        #expect(command(press(" ", .command, keyCode: Self.spaceKey)) == nil)
        #expect(command(press(" ", [.control, .shift], keyCode: Self.spaceKey)) == nil)
        #expect(command(press(".", .command, keyCode: Self.periodKey)) == nil)
    }

    @Test func anUnrelatedKeyIsNotACommand() {
        #expect(command(press("k", .control, keyCode: 40)) == nil)
    }

    // MARK: The host wins

    /// The rule the host already states for its own map, applied to these
    /// two: an id it mentions is an id it owns, whatever it says about it.
    @Test func aHostBindingReplacesTheDefault() {
        let host = [
            EditorAssistCommand.triggerSuggest.actionID: [
                EditorShortcut(key: "i", modifiers: [.control, .option]),
            ],
        ]

        #expect(command(press(" ", .control, keyCode: Self.spaceKey), host: host) == nil)
    }

    /// An empty list is the reader deliberately clearing a command, and it
    /// must not fall back to a default they were removing.
    @Test func aClearedCommandStaysCleared() {
        let host = [EditorAssistCommand.quickFix.actionID: [EditorShortcut]()]

        #expect(command(press(".", .control, keyCode: Self.periodKey), host: host) == nil)
    }

    /// A host that mentions one of them does not speak for the other.
    @Test func mentioningOneCommandLeavesTheOtherOnItsDefault() {
        let host = [EditorAssistCommand.triggerSuggest.actionID: [EditorShortcut]()]

        #expect(
            command(press(".", .control, keyCode: Self.periodKey), host: host)
                == EditorAssistCommand.quickFix.actionID
        )
    }

    // MARK: The table itself

    @Test func everyCommandHasADefaultAndTheyAreDistinct() {
        let chords = EditorAssistCommand.allCases.map(\.shortcut)

        #expect(chords.count == EditorAssistCommand.allCases.count)
        #expect(Set(chords.map { "\($0.key)\($0.modifiers.rawValue)" }).count == chords.count)
        #expect(EditorAssistCommand.defaults.count == EditorAssistCommand.allCases.count)
    }

    /// The ids the engine dispatches on are the ids the table is keyed by. A
    /// mismatch here is a key that is matched and then falls through
    /// `runCommand`'s `default`, which is silence again.
    @Test func theTableIsKeyedByTheDispatchedIds() {
        for command in EditorAssistCommand.allCases {
            #expect(EditorAssistCommand.defaults[command.actionID] == [command.shortcut])
            #expect(EditorAssistCommand.named(command.actionID) == command)
        }
    }
}
