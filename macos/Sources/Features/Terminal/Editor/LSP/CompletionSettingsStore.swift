import Foundation

/// How long the caret rests before the completion list asks for
/// suggestions.
///
/// Three named points rather than a millisecond field, because the useful
/// range is narrow and the number is not the interesting part. Under about
/// 150ms a suggestion still reads as instantaneous; past about 300ms it
/// reads as the editor being slow. A free-text field mostly offers the
/// chance to type 5000 and conclude the feature is broken — and the two
/// values worth having either side of the default are "don't wait" and
/// "wait longer", which is what these are.
enum CompletionDelay: String, CaseIterable, Identifiable, Sendable {
    /// One request per keystroke. Honest about what it costs: it is the
    /// setting for a fast machine and a small project, not a free upgrade.
    case immediate

    /// The engine's own default, mirrored here rather than reached for —
    /// `CodeNSTextView.completionFetchDelay` carries the reasoning for the
    /// number and cannot be read from this side of the boundary.
    case standard

    /// For a server slow enough that a burst of requests it will never
    /// finish is worse than waiting for one it will.
    case relaxed

    static let `default` = CompletionDelay.standard

    var id: String { rawValue }

    var duration: Duration {
        switch self {
        case .immediate: return .zero
        case .standard: return .milliseconds(120)
        case .relaxed: return .milliseconds(300)
        }
    }

    var title: String {
        switch self {
        case .immediate: return "Immediately"
        case .standard: return "After a Short Pause"
        case .relaxed: return "After a Longer Pause"
        }
    }

    /// The milliseconds, for the row that has to admit what it chose.
    ///
    /// A picker of three adjectives is friendlier than a number field and
    /// worse at answering "is my server being asked too often". Both, then:
    /// the adjective is the control, the number is the caption.
    var detail: String {
        let milliseconds = duration.components.attoseconds / 1_000_000_000_000_000
            + duration.components.seconds * 1000
        return milliseconds == 0 ? "no delay" : "\(milliseconds) ms"
    }

    /// Reading is total: an unknown or absent string is the default rather
    /// than a failure. A defaults entry written by a later build — or by
    /// somebody with a plist editor — must not be able to leave the editor
    /// with no delay at all.
    static func named(_ raw: String) -> CompletionDelay {
        CompletionDelay(rawValue: raw) ?? .default
    }
}

/// The completion preferences as one value.
///
/// A value, and not a reference the engine could hold onto, for the reason
/// the whole `Editor/Engine/` boundary exists: the engine is handed what it
/// needs and asks nobody. This is the shape the host folds into
/// `CodeEditorConfiguration` before handing it over.
struct CompletionSettings: Equatable, Sendable {
    var isEnabled: Bool = true
    var delay: CompletionDelay = .default
    var usesBufferWords: Bool = true
}

/// Reads and writes the completion preferences, keyed — where it is keyed
/// at all — by **language id**.
///
/// The sibling store, `LSPServerOverrideStore`, is keyed by the registry's
/// **default command**, and the difference is deliberate rather than an
/// oversight waiting to be tidied up. "No completion in Markdown" is a fact
/// about a *language*: it is true of every file the reader would call
/// Markdown, whatever binary happens to serve it, and it stays true if the
/// binary is replaced. "Point this at a different binary" is a fact about a
/// *binary*, which is why four language ids — `typescript`,
/// `typescriptreact`, `javascript`, `javascriptreact` — share one override
/// and must not share one completion switch. Turning completion off for
/// `.tsx` and finding it also off for every `.js` file in the project is
/// the bug that unifying these keys would produce. Whoever is tempted to
/// make the two stores agree should read both comments first; the third
/// store in this family, `LanguageTrustStore`, is keyed by extension id for
/// a third reason of its own.
///
/// In `UserDefaults` and never in `GuiConfigStore`: an unrecognised key in
/// `gui-settings` makes the Ghostty core raise a configuration error at the
/// user, so everything Phantom adds stays out of it. Same reasoning as
/// `EditorSettings`, which is where the rest of the editor's keys live.
///
/// The per-language table is **one blob under one key**, and an absent
/// entry means "follow the default" rather than "off". That is what lets
/// the default change in a later build without rewriting settings people
/// already have: a reader who never touched Markdown has nothing stored for
/// it, so they get whatever this build thinks the answer should be. It is
/// also why `setPreference` takes an optional and *removes* on the default
/// value instead of writing it — a table that eagerly records every
/// language it was shown would pin all of them to today's answer.
enum CompletionSettingsStore {
    static let enabledKey = "EditorCompletionEnabled"
    static let delayKey = "EditorCompletionDelay"
    static let bufferWordsKey = "EditorCompletionUsesBufferWords"
    static let byLanguageKey = "EditorCompletionByLanguage"

    /// Every boolean here defaults to **true** when absent, which
    /// `UserDefaults.bool(forKey:)` cannot express — it answers `false` for
    /// a key nobody has written. Reading through `object(forKey:)` is the
    /// idiom `SidebarPane.isEnabled` already uses, and it is also what
    /// `@AppStorage(key) var x = true` does, so the Settings screen and this
    /// store cannot disagree about an untouched install.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var usesBufferWords: Bool {
        UserDefaults.standard.object(forKey: bufferWordsKey) as? Bool ?? true
    }

    static var delay: CompletionDelay {
        guard let raw = UserDefaults.standard.string(forKey: delayKey) else { return .default }
        return .named(raw)
    }

    /// The globals as one value, for the caller that wants a snapshot
    /// rather than three lookups it has to keep in the same order.
    static var settings: CompletionSettings {
        CompletionSettings(isEnabled: isEnabled, delay: delay, usesBufferWords: usesBufferWords)
    }

    // MARK: Per language

    /// What a language with no entry of its own does.
    ///
    /// The one place to change if that answer ever flips, and the reason
    /// the table stores deviations rather than answers: every install that
    /// never touched a given language picks the new value up, and nobody's
    /// settings have to be rewritten to give it to them.
    static let languageDefault = true

    static var byLanguage: [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: byLanguageKey),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return decoded
    }

    /// What the reader decided for one language, or nil when they never
    /// said — which is not the same as "off" and must never collapse into
    /// it.
    static func preference(forLanguage languageID: String) -> Bool? {
        byLanguage[normalized(languageID)]
    }

    /// Records a decision, or forgets one when `enabled` is nil.
    ///
    /// The whole entry disappears once the table empties, so an install
    /// where every language was switched off and back on again is
    /// indistinguishable from one nobody ever touched. "Absent means
    /// follow the default" has to be true of the blob as well as of the
    /// entries inside it, or the first person to open this screen would
    /// freeze their defaults by looking at them.
    static func setPreference(_ enabled: Bool?, forLanguage languageID: String) {
        let key = normalized(languageID)
        guard !key.isEmpty else { return }

        var current = byLanguage
        if let enabled {
            current[key] = enabled
        } else {
            current.removeValue(forKey: key)
        }

        guard !current.isEmpty else {
            UserDefaults.standard.removeObject(forKey: byLanguageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: byLanguageKey)
    }

    /// Stores a decision only when it *differs* from the default, and
    /// clears the entry when it doesn't.
    ///
    /// The gesture the screen offers is a switch, which has two positions
    /// and no way to express "I have no opinion" — so the third state has
    /// to be inferred, and this is where. Writing today's default for every
    /// row somebody flicked twice would pin those languages to this build's
    /// answer forever, which is the exact outcome storing deviations
    /// exists to avoid.
    static func setEnabled(_ enabled: Bool, forLanguage languageID: String) {
        setPreference(enabled == languageDefault ? nil : enabled, forLanguage: languageID)
    }

    /// Forgets every per-language decision.
    ///
    /// The only cheap way back from a table somebody filled in months ago
    /// and cannot now remember — and the state it restores is genuinely
    /// "untouched", not "all switched on", since it removes the key rather
    /// than filling it with `true`s.
    static func clearLanguagePreferences() {
        UserDefaults.standard.removeObject(forKey: byLanguageKey)
    }

    /// Whether the list may open for a language at all.
    ///
    /// The global switch is a *master* switch: with it off, a per-language
    /// `true` does not bring completion back. That asymmetry is the point
    /// of having a global one — somebody who turns the feature off is
    /// turning the feature off, not opening a negotiation with a table they
    /// filled in months ago.
    ///
    /// A nil language is a file nothing claims. It follows the global
    /// answer, because the alternative is a plain `.txt` file being the one
    /// place completion silently never works.
    static func isEnabled(forLanguage languageID: String?) -> Bool {
        guard isEnabled else { return false }
        guard let languageID, !languageID.isEmpty else { return languageDefault }
        return preference(forLanguage: languageID) ?? languageDefault
    }

    /// The globals plus the per-language answer, folded into the value the
    /// host hands the engine.
    static func settings(forLanguage languageID: String?) -> CompletionSettings {
        settings(
            forLanguage: languageID,
            isEnabled: isEnabled,
            delay: delay,
            usesBufferWords: usesBufferWords
        )
    }

    /// The same fold, from globals the caller already holds.
    ///
    /// For the host, which observes the three global keys through
    /// `@AppStorage` — that observation is what republishes the editor when
    /// a switch moves in Settings, and a property nothing reads is a
    /// property somebody deletes in a tidy-up, taking the republish with it
    /// and leaving a preference that waits for an unrelated update. So they
    /// are passed in and used rather than shadowed by a second read.
    ///
    /// The per-language rule stays here in either case. That is the point of
    /// the overload: a caller holding the globals is one keystroke away from
    /// writing `isEnabled && …` itself, and then "the master switch wins"
    /// would be stated in two places that could disagree.
    static func settings(
        forLanguage languageID: String?,
        isEnabled: Bool,
        delay: CompletionDelay,
        usesBufferWords: Bool
    ) -> CompletionSettings {
        guard isEnabled else {
            return CompletionSettings(
                isEnabled: false,
                delay: delay,
                usesBufferWords: usesBufferWords
            )
        }
        let allowed = languageID.flatMap { $0.isEmpty ? nil : preference(forLanguage: $0) }
        return CompletionSettings(
            isEnabled: allowed ?? languageDefault,
            delay: delay,
            usesBufferWords: usesBufferWords
        )
    }

    /// Language ids arrive lower-cased from `LanguageManifest` and from
    /// `LSPServerRegistry` alike, so folding here only matters for a value
    /// somebody typed. Doing it anyway costs nothing and keeps `Swift` and
    /// `swift` from being two rows in one table.
    private static func normalized(_ languageID: String) -> String {
        languageID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
