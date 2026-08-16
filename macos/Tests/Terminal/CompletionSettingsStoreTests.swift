import Foundation
@testable import Ghostty
import Testing

/// The completion preferences, saved and read back through `UserDefaults`.
///
/// Serialized for the same reason `LSPServerOverrideStoreTests` is: these
/// save and restore the real `UserDefaults` entries a locally-running
/// Phantom also reads, and interleaved save/restore pairs between
/// concurrently-running tests can put back the wrong snapshot. `.serialized`
/// only orders tests *within* a suite, so everything that touches these four
/// keys has to live in this one.
///
/// `@MainActor` because two of the tests reach `GuiConfigStore.shared`,
/// which is main-actor isolated. Harmless for the rest, which do nothing
/// that cares which actor runs them.
@Suite(.serialized)
@MainActor
struct CompletionSettingsStoreTests {
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

    // MARK: Defaults

    /// The whole point of the absent-means-default reading: an install
    /// nobody has configured completes, from the buffer, after the engine's
    /// own pause.
    @Test func anUntouchedInstallCompletes() {
        withCleanDefaults {
            #expect(CompletionSettingsStore.isEnabled)
            #expect(CompletionSettingsStore.usesBufferWords)
            #expect(CompletionSettingsStore.delay == .standard)
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "swift"))
        }
    }

    /// `UserDefaults.bool(forKey:)` answers `false` for a key nobody wrote,
    /// which would turn every default-on switch off on first launch. This
    /// is the regression test for reading them through `object(forKey:)`
    /// instead.
    @Test func anAbsentKeyIsNotReadAsFalse() {
        withCleanDefaults {
            #expect(UserDefaults.standard.object(forKey: CompletionSettingsStore.enabledKey) == nil)
            #expect(CompletionSettingsStore.isEnabled)
            #expect(UserDefaults.standard.bool(forKey: CompletionSettingsStore.enabledKey) == false)
        }
    }

    @Test func theGlobalSwitchReadsBack() {
        withCleanDefaults {
            UserDefaults.standard.set(false, forKey: CompletionSettingsStore.enabledKey)
            #expect(!CompletionSettingsStore.isEnabled)

            UserDefaults.standard.set(true, forKey: CompletionSettingsStore.enabledKey)
            #expect(CompletionSettingsStore.isEnabled)
        }
    }

    // MARK: Delay

    @Test func theDelayOptionsAreTheDurationsTheyClaim() {
        #expect(CompletionDelay.immediate.duration == Duration.zero)
        #expect(CompletionDelay.standard.duration == Duration.milliseconds(120))
        #expect(CompletionDelay.relaxed.duration == Duration.milliseconds(300))
    }

    /// The caption under the picker has to state the number the adjective
    /// stands for, or "After a Short Pause" is unanswerable.
    @Test func theDelayCaptionStatesTheNumber() {
        #expect(CompletionDelay.immediate.detail == "no delay")
        #expect(CompletionDelay.standard.detail == "120 ms")
        #expect(CompletionDelay.relaxed.detail == "300 ms")
    }

    /// A defaults entry written by a later build — or by somebody with a
    /// plist editor — must not be able to leave the editor with a delay it
    /// has no name for.
    @Test func anUnknownDelayReadsAsTheDefault() {
        withCleanDefaults {
            UserDefaults.standard.set("glacial", forKey: CompletionSettingsStore.delayKey)
            #expect(CompletionSettingsStore.delay == .standard)

            UserDefaults.standard.set("", forKey: CompletionSettingsStore.delayKey)
            #expect(CompletionSettingsStore.delay == .standard)
        }
    }

    @Test func aChosenDelayReadsBack() {
        withCleanDefaults {
            UserDefaults.standard.set(
                CompletionDelay.relaxed.rawValue,
                forKey: CompletionSettingsStore.delayKey
            )
            #expect(CompletionSettingsStore.delay == .relaxed)
            #expect(CompletionSettingsStore.settings.delay == .relaxed)
        }
    }

    // MARK: Per language

    @Test func aLanguageNobodyTouchedHasNoStoredPreference() {
        withCleanDefaults {
            #expect(CompletionSettingsStore.preference(forLanguage: "markdown") == nil)
            #expect(CompletionSettingsStore.byLanguage.isEmpty)
        }
    }

    @Test func switchingOneLanguageOffLeavesTheRestAlone() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")

            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "markdown"))
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "swift"))
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "typescript"))
        }
    }

    /// The crux of "one blob, and an absent key means follow the default".
    ///
    /// Switching a language back on **removes** its entry rather than
    /// writing today's answer into it. A table that recorded `true` for
    /// every row somebody flicked twice would pin those languages to this
    /// build's default forever, which is exactly what storing deviations
    /// exists to avoid.
    @Test func switchingALanguageBackOnForgetsItRatherThanRecordingIt() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")
            #expect(CompletionSettingsStore.preference(forLanguage: "markdown") == false)

            CompletionSettingsStore.setEnabled(true, forLanguage: "markdown")
            #expect(CompletionSettingsStore.preference(forLanguage: "markdown") == nil)
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "markdown"))
        }
    }

    /// "Absent means follow the default" has to be true of the blob as well
    /// as of the entries inside it, or the first person to open this screen
    /// would freeze their defaults by looking at it.
    @Test func emptyingTheTableRemovesTheKeyEntirely() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")
            #expect(UserDefaults.standard.data(forKey: CompletionSettingsStore.byLanguageKey) != nil)

            CompletionSettingsStore.setEnabled(true, forLanguage: "markdown")
            #expect(UserDefaults.standard.object(forKey: CompletionSettingsStore.byLanguageKey) == nil)
        }
    }

    /// An explicit `nil` is how a caller says "forget this", which is not
    /// the same gesture as switching it on and must stay reachable even if
    /// the default flips.
    @Test func settingAPreferenceToNilForgetsIt() {
        withCleanDefaults {
            CompletionSettingsStore.setPreference(false, forLanguage: "yaml")
            #expect(CompletionSettingsStore.preference(forLanguage: "yaml") == false)

            CompletionSettingsStore.setPreference(nil, forLanguage: "yaml")
            #expect(CompletionSettingsStore.preference(forLanguage: "yaml") == nil)
        }
    }

    /// A `true` written explicitly is kept, unlike one written through
    /// `setEnabled`. The distinction is what makes the store survive the
    /// default changing: the day `languageDefault` is false, this is the
    /// entry that means "on anyway".
    @Test func anExplicitTrueIsStored() {
        withCleanDefaults {
            CompletionSettingsStore.setPreference(true, forLanguage: "yaml")
            #expect(CompletionSettingsStore.preference(forLanguage: "yaml") == true)
            #expect(CompletionSettingsStore.byLanguage["yaml"] == true)
        }
    }

    @Test func severalLanguagesShareOneBlob() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")
            CompletionSettingsStore.setEnabled(false, forLanguage: "yaml")

            #expect(CompletionSettingsStore.byLanguage.count == 2)
            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "markdown"))
            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "yaml"))
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "swift"))
        }
    }

    @Test func clearingForgetsEveryLanguage() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")
            CompletionSettingsStore.setEnabled(false, forLanguage: "yaml")

            CompletionSettingsStore.clearLanguagePreferences()

            #expect(CompletionSettingsStore.byLanguage.isEmpty)
            #expect(UserDefaults.standard.object(forKey: CompletionSettingsStore.byLanguageKey) == nil)
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "markdown"))
        }
    }

    @Test func languageIDsAreFoldedSoOneLanguageIsOneRow() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "  Swift ")

            #expect(CompletionSettingsStore.byLanguage.count == 1)
            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "swift"))
            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "SWIFT"))
        }
    }

    @Test func anEmptyLanguageIDIsIgnored() {
        withCleanDefaults {
            CompletionSettingsStore.setPreference(false, forLanguage: "")
            CompletionSettingsStore.setPreference(false, forLanguage: "   ")
            #expect(CompletionSettingsStore.byLanguage.isEmpty)
        }
    }

    /// A blob this build cannot decode reads as **empty**, which means every
    /// language follows the default. Absent never means off.
    @Test func anUnreadableBlobReadsAsNoPreferences() {
        withCleanDefaults {
            UserDefaults.standard.set(
                Data("not json".utf8),
                forKey: CompletionSettingsStore.byLanguageKey
            )
            #expect(CompletionSettingsStore.byLanguage.isEmpty)
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "swift"))
        }
    }

    // MARK: The master switch

    /// Somebody who turns completion off is turning it off, not opening a
    /// negotiation with a table they filled in months ago.
    @Test func theGlobalSwitchBeatsAPerLanguageYes() {
        withCleanDefaults {
            CompletionSettingsStore.setPreference(true, forLanguage: "swift")
            UserDefaults.standard.set(false, forKey: CompletionSettingsStore.enabledKey)

            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "swift"))
            #expect(!CompletionSettingsStore.settings(forLanguage: "swift").isEnabled)
        }
    }

    /// A file nothing claims follows the global answer, because the
    /// alternative is a plain `.txt` being the one place completion silently
    /// never works.
    @Test func aFileWithNoLanguageFollowsTheGlobalSwitch() {
        withCleanDefaults {
            #expect(CompletionSettingsStore.isEnabled(forLanguage: nil))

            UserDefaults.standard.set(false, forKey: CompletionSettingsStore.enabledKey)
            #expect(!CompletionSettingsStore.isEnabled(forLanguage: nil))
        }
    }

    /// The value the host folds into `CodeEditorConfiguration`: the
    /// per-language answer for `isEnabled`, the globals for the rest.
    @Test func theFoldedValueCarriesBothHalves() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")
            UserDefaults.standard.set(false, forKey: CompletionSettingsStore.bufferWordsKey)
            UserDefaults.standard.set(
                CompletionDelay.immediate.rawValue,
                forKey: CompletionSettingsStore.delayKey
            )

            let markdown = CompletionSettingsStore.settings(forLanguage: "markdown")
            #expect(!markdown.isEnabled)
            #expect(!markdown.usesBufferWords)
            #expect(markdown.delay == .immediate)

            let swift = CompletionSettingsStore.settings(forLanguage: "swift")
            #expect(swift.isEnabled)
            #expect(swift.delay == .immediate)
        }
    }

    /// The overload the host calls, holding globals it observed through
    /// `@AppStorage`, has to reach the same answer as the one that reads
    /// them here. Two folds that could disagree would be two places the
    /// master-switch rule lives.
    @Test func bothFoldsAgree() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")

            for language in ["markdown", "swift", ""] {
                #expect(
                    CompletionSettingsStore.settings(forLanguage: language)
                        == CompletionSettingsStore.settings(
                            forLanguage: language,
                            isEnabled: CompletionSettingsStore.isEnabled,
                            delay: CompletionSettingsStore.delay,
                            usesBufferWords: CompletionSettingsStore.usesBufferWords
                        ),
                    "the two folds disagree for \(language.isEmpty ? "an empty id" : language)"
                )
            }
        }
    }

    /// The caller's globals are honoured, not silently re-read. A host that
    /// observed `false` must not be overruled by a store that has not
    /// noticed yet.
    @Test func theCallersGlobalsWinOverTheStoresOwnRead() {
        withCleanDefaults {
            let folded = CompletionSettingsStore.settings(
                forLanguage: "swift",
                isEnabled: false,
                delay: .relaxed,
                usesBufferWords: false
            )
            #expect(!folded.isEnabled)
            #expect(folded.delay == .relaxed)
            #expect(!folded.usesBufferWords)
            #expect(CompletionSettingsStore.isEnabled)
        }
    }

    /// A per-language `false` still bites when the caller's global is on,
    /// which is the half of the rule the overload exists to keep in here.
    @Test func theOverloadStillAppliesThePerLanguageRule() {
        withCleanDefaults {
            CompletionSettingsStore.setEnabled(false, forLanguage: "markdown")

            #expect(!CompletionSettingsStore.settings(
                forLanguage: "markdown",
                isEnabled: true,
                delay: .standard,
                usesBufferWords: true
            ).isEnabled)

            #expect(CompletionSettingsStore.settings(
                forLanguage: "swift",
                isEnabled: true,
                delay: .standard,
                usesBufferWords: true
            ).isEnabled)
        }
    }

    // MARK: The keying decision

    /// The reason the two stores are keyed differently, as a test rather
    /// than only as a comment on each of them.
    ///
    /// `typescript`, `typescriptreact`, `javascript` and `javascriptreact`
    /// are one binary and four languages. An override follows the binary, so
    /// it reaches all four; a completion switch follows the language, so it
    /// reaches exactly one. Unifying the keys would make "no completion in
    /// `.tsx`" also mean "no completion in every `.js` file in the project",
    /// which is the bug this asserts cannot happen.
    @Test func completionIsKeyedByLanguageWhileAnOverrideIsKeyedByBinary() {
        withCleanDefaults {
            let typescript = LSPServerRegistry.server(forLanguage: "typescriptreact")!
            let javascript = LSPServerRegistry.server(forLanguage: "javascript")!
            #expect(typescript.command == javascript.command)

            CompletionSettingsStore.setEnabled(false, forLanguage: typescript.languageID)

            #expect(!CompletionSettingsStore.isEnabled(forLanguage: "typescriptreact"))
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "javascript"))
            #expect(CompletionSettingsStore.isEnabled(forLanguage: "typescript"))
        }
    }

    /// The four keys are distinct from every other store's, so no write here
    /// can quietly clobber an override or a trust record.
    @Test func theKeysCollideWithNothing() {
        let others = [
            LSPServerOverrideStore.defaultsKey,
            LanguageTrustStore.defaultsKey,
            LanguagePromotionStore.defaultsKey,
            EditorSettings.showsMinimapKey,
        ]
        for key in Self.keys {
            #expect(!others.contains(key), "\(key) collides with another store's key")
        }
        #expect(Set(Self.keys).count == Self.keys.count)
    }

    /// Settings keys go in `UserDefaults` and never in `gui-settings`: an
    /// unrecognised key there makes the Ghostty core raise a configuration
    /// error at the user, which is a real failure mode and not a style
    /// preference.
    @Test func noCompletionKeyReachesTheGhosttyConfig() {
        for key in Self.keys {
            #expect(
                GuiConfigStore.shared.string(key) == nil,
                "\(key) is in gui-settings; the core will raise a configuration error for it"
            )
        }
    }
}
