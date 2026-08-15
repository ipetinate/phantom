import AppKit
@testable import Ghostty
import Testing

/// That a changed completion preference is a change the editor *notices*.
///
/// The bug this guards is the one recorded on
/// `CodeEditorConfiguration.showsMinimap`: a setting read once when a view
/// was built does nothing until the file is reopened, and it does nothing
/// *silently* — the switch moves, the preference is saved, and the editor
/// carries on as before. `applyAppearance` compares whole configurations to
/// decide whether anything happened, so a preference that does not
/// participate in that comparison is a preference that gets swallowed.
///
/// Written the way `AppearanceGuardTests` writes the same assertion for
/// wrapping and bracket colouring, and for the same reason: the values the
/// guard compares have to really compare.
@MainActor
struct CompletionConfigurationGuardTests {
    @Test func switchingCompletionOffIsAChange() {
        var changed = CodeEditorConfiguration.default
        changed.completionEnabled.toggle()
        #expect(changed != CodeEditorConfiguration.default)
    }

    @Test func switchingTheBufferFallbackOffIsAChange() {
        var changed = CodeEditorConfiguration.default
        changed.completesFromBuffer.toggle()
        #expect(changed != CodeEditorConfiguration.default)
    }

    @Test func changingTheFetchDelayIsAChange() {
        var changed = CodeEditorConfiguration.default
        changed.completionFetchDelay = CompletionDelay.relaxed.duration
        #expect(changed != CodeEditorConfiguration.default)
    }

    /// Three defaults, one number. The engine carries its own
    /// `completionFetchDelay` so it works with no host at all; Settings
    /// offers `.standard`; the configuration handed across the seam has to
    /// start at the same place, or the first thing a user changes is a
    /// setting that was already not what the editor was doing.
    @Test func theEnginesDefaultAndTheSettingsDefaultAgree() {
        #expect(CodeEditorConfiguration.default.completionFetchDelay
            == CompletionDelay.standard.duration)
        #expect(CompletionDelay.default == .standard)
        #expect(CodeEditorConfiguration.default.completionEnabled)
        #expect(CodeEditorConfiguration.default.completesFromBuffer)
    }

    /// The whole configuration is a value the engine is handed. Nothing in
    /// it may be a reference the host can mutate behind the comparison's
    /// back, or the guard would compare a value to itself and always find
    /// it unchanged.
    @Test func theCompletionFieldsAreValues() {
        var one = CodeEditorConfiguration.default
        let two = one
        one.completionEnabled = false
        #expect(two.completionEnabled)
    }
}

/// The fold from four stored preferences to the three fields the engine
/// gets.
///
/// This is the seam the host crosses: `UserDefaults` on one side,
/// `CodeEditorConfiguration` on the other, and the language id resolved to a
/// plain `Bool` in between — because the engine has no idea what language it
/// is drawing and must not learn.
@Suite(.serialized)
@MainActor
struct CompletionConfigurationFoldTests {
    private static let keys = [
        CompletionSettingsStore.enabledKey,
        CompletionSettingsStore.delayKey,
        CompletionSettingsStore.bufferWordsKey,
        CompletionSettingsStore.byLanguageKey,
    ]

    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let stored = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        for (key, _) in stored { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in stored {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    /// A configuration folded for one language differs from the same
    /// configuration folded for another, which is what makes switching
    /// Markdown off reach the editor as a change rather than as nothing.
    @Test func twoLanguagesFoldToTwoDifferentConfigurations() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")

            var markdown = CodeEditorConfiguration.default
            let markdownSettings = CompletionSettingsStore.settings(forLanguage: "markdown")
            markdown.completionEnabled = markdownSettings.isEnabled
            markdown.completesFromBuffer = markdownSettings.usesBufferWords
            markdown.completionFetchDelay = markdownSettings.delay.duration

            var swift = CodeEditorConfiguration.default
            let swiftSettings = CompletionSettingsStore.settings(forLanguage: "swift")
            swift.completionEnabled = swiftSettings.isEnabled
            swift.completesFromBuffer = swiftSettings.usesBufferWords
            swift.completionFetchDelay = swiftSettings.delay.duration

            #expect(markdown != swift)
            #expect(!markdown.completionEnabled)
            #expect(swift.completionEnabled)
            #expect(swift == CodeEditorConfiguration.default)
        }
    }

    /// The store is read fresh, not captured. A snapshot taken once and
    /// reused is precisely how a setting stops taking effect until the file
    /// is reopened, so the fold has to answer differently the moment the
    /// preference changes — with no reload, no notification, and nothing
    /// rebuilt.
    @Test func theFoldAnswersDifferentlyTheMomentThePreferenceChanges() {
        withCleanDefaults {
            #expect(CompletionSettingsStore.settings(forLanguage: "swift").isEnabled)

            CompletionSettingsStore.setEnabled(false, forLanguage: "swift")
            #expect(!CompletionSettingsStore.settings(forLanguage: "swift").isEnabled)

            UserDefaults.standard.set(
                CompletionDelay.immediate.rawValue,
                forKey: CompletionSettingsStore.delayKey
            )
            #expect(CompletionSettingsStore.settings(forLanguage: "swift").delay.duration
                == Duration.zero)
        }
    }
}
