import Foundation
@testable import Ghostty
import Testing

/// The editor's behaviour switches, seen the way the settings pane sees
/// them: through `isEnabled(_:)`, through `set(_:to:)`, and through the
/// words `Key` carries for the reader.
///
/// `.serialized` and `@MainActor` for the reason `CompletionSettingsStoreTests`
/// is both: these write the same storage a locally-running Phantom reads,
/// and save/restore pairs interleaved between concurrent tests can put back
/// the wrong snapshot.
///
/// The snapshot is taken from `UserDefaults`, which is where
/// `EditorFeatureSettings` keeps these keys. If that backing moves,
/// `withBehavioursCleared` has to move with it — otherwise these tests stop
/// isolating and start leaving values behind in a real install.
///
/// It must never move back to `GuiConfigStore`: that store writes
/// `gui-settings`, the main config includes it, and the Ghostty core reports
/// a key it does not know as a configuration error at the reader.
@Suite(.serialized)
@MainActor
struct EditorFeatureSettingsTests {
    /// Runs `body` against storage where none of the keys is written, and
    /// puts back exactly what was there — including "nothing was there",
    /// which is the state most installs are in and the one the first test
    /// below is about.
    private func withBehavioursCleared(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let stored = EditorFeatureSettings.Key.allCases.map {
            ($0.rawValue, defaults.object(forKey: $0.rawValue))
        }
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

    // MARK: Reading and writing

    /// A reader who has never opened this pane gets the whole editor. The
    /// alternative — absent meaning off — would read as a regression on the
    /// build that shipped the switches.
    @Test func aBehaviourNobodyHasTouchedIsOn() {
        withBehavioursCleared {
            for key in EditorFeatureSettings.Key.allCases {
                #expect(
                    EditorFeatureSettings.shared.isEnabled(key),
                    "\(key.rawValue) is off before anybody switched it off"
                )
            }
        }
    }

    @Test func switchingOneOffReadsBackOff() {
        withBehavioursCleared {
            let settings = EditorFeatureSettings.shared
            for key in EditorFeatureSettings.Key.allCases {
                settings.set(key, to: false)
                #expect(!settings.isEnabled(key), "\(key.rawValue) stayed on after being set off")

                settings.set(key, to: true)
                #expect(settings.isEnabled(key), "\(key.rawValue) stayed off after being set on")
            }
        }
    }

    /// One switch, one behaviour. Two keys sharing a storage name would
    /// read as a switch that moves another switch, which is the kind of
    /// thing a copied line produces and nothing else catches.
    @Test func switchingOneOffLeavesTheOthersOn() {
        withBehavioursCleared {
            let settings = EditorFeatureSettings.shared
            for key in EditorFeatureSettings.Key.allCases {
                settings.set(key, to: false)
                defer { settings.set(key, to: true) }

                for other in EditorFeatureSettings.Key.allCases where other != key {
                    #expect(
                        settings.isEnabled(other),
                        "switching \(key.rawValue) off also switched \(other.rawValue) off"
                    )
                }
            }
        }
    }

    // MARK: The words the pane draws

    /// The pane draws `title` and `detail` for every case it finds in
    /// `allCases`, so a seventh behaviour added without words for the reader
    /// shows up as a blank row rather than as a compile error. This is what
    /// stops that.
    @Test func everyBehaviourHasWordsForTheReader() {
        for key in EditorFeatureSettings.Key.allCases {
            #expect(!trimmed(key.title).isEmpty, "\(key.rawValue) has no title")
            #expect(!trimmed(key.detail).isEmpty, "\(key.rawValue) has no detail")

            /// A detail that repeats the title tells the reader nothing
            /// about what turning the behaviour off costs them, which is the
            /// only reason the second line is drawn at all.
            #expect(
                trimmed(key.detail) != trimmed(key.title),
                "\(key.rawValue) repeats its title as its detail"
            )
        }
    }

    /// Two rows reading the same thing is a reader picking between them by
    /// guessing.
    @Test func noTwoBehavioursShareAName() {
        let keys = EditorFeatureSettings.Key.allCases
        #expect(Set(keys.map(\.rawValue)).count == keys.count)
        #expect(Set(keys.map(\.title)).count == keys.count)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
