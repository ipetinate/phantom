import Foundation
@testable import Ghostty
import Testing

/// Per-server overrides, saved and read back through `UserDefaults` — and
/// `LSPCenter.effectiveDefinition`, the merge of that override with a
/// registry default, kept in the same suite rather than a separate one.
///
/// Serialized like the icon store's own tests: these save and restore the
/// real `UserDefaults` entry a locally-running Phantom also reads, and
/// interleaved save/restore pairs between concurrently-running tests can
/// put back the wrong snapshot. `.serialized` only orders tests *within* a
/// suite — splitting `effectiveDefinition`'s tests into a suite of their
/// own reintroduced exactly that race, since Swift Testing still runs the
/// two suites against each other concurrently by default. One suite is
/// what actually guarantees no two tests touch this key at once.
///
/// `@MainActor` because `effectiveDefinition` is a `@MainActor` member of
/// `LSPCenter` — harmless for the store-only tests, which do nothing that
/// cares which actor runs them.
@Suite(.serialized)
@MainActor
struct LSPServerOverrideStoreTests {
    private func withCleanDefaults(_ body: () -> Void) {
        let key = LSPServerOverrideStore.defaultsKey
        let stored = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func withNothingSetThereIsNoOverride() {
        withCleanDefaults {
            #expect(LSPServerOverrideStore.override(for: "kotlin-language-server") == nil)
        }
    }

    @Test func aSavedOverrideReadsBackAsIs() {
        withCleanDefaults {
            var override = LSPServerOverride()
            override.command = "/usr/local/bin/kotlin-language-server"
            override.arguments = "--verbose"
            override.initializationOptionsJSON = #"{"foo": true}"#

            LSPServerOverrideStore.set(override, for: "kotlin-language-server")

            #expect(LSPServerOverrideStore.override(for: "kotlin-language-server") == override)
        }
    }

    /// Setting an override to something empty removes it — a user who
    /// clears every field is saying "use the default", not "use three
    /// blank strings".
    @Test func settingAnEmptyOverrideRemovesIt() {
        withCleanDefaults {
            var override = LSPServerOverride()
            override.command = "/opt/homebrew/bin/kotlin-language-server"
            LSPServerOverrideStore.set(override, for: "kotlin-language-server")
            #expect(LSPServerOverrideStore.override(for: "kotlin-language-server") != nil)

            LSPServerOverrideStore.set(LSPServerOverride(), for: "kotlin-language-server")
            #expect(LSPServerOverrideStore.override(for: "kotlin-language-server") == nil)
        }
    }

    /// Overrides for different servers don't collide — keyed by the
    /// default command, not by insertion order or a shared blob.
    @Test func overridesForDifferentServersAreIndependent() {
        withCleanDefaults {
            var kotlin = LSPServerOverride()
            kotlin.command = "/custom/kotlin-language-server"
            LSPServerOverrideStore.set(kotlin, for: "kotlin-language-server")

            var vue = LSPServerOverride()
            vue.arguments = "--stdio --log verbose"
            LSPServerOverrideStore.set(vue, for: "vue-language-server")

            #expect(LSPServerOverrideStore.override(for: "kotlin-language-server")?.command == kotlin.command)
            #expect(LSPServerOverrideStore.override(for: "vue-language-server")?.arguments == vue.arguments)
        }
    }

    @Test func blankFieldsMakeAnOverrideEmpty() {
        #expect(LSPServerOverride().isEmpty)
        #expect(LSPServerOverride(command: "  ", arguments: "", initializationOptionsJSON: " \n").isEmpty)
        #expect(!LSPServerOverride(command: "x", arguments: "", initializationOptionsJSON: "").isEmpty)
    }

    // MARK: LSPCenter.effectiveDefinition — the merge `server(for:)` actually launches against

    @Test func withNoOverrideTheDefaultPassesThroughUnchanged() {
        withCleanDefaults {
            let base = LSPServerRegistry.server(forLanguage: "kotlin")!
            #expect(LSPCenter.effectiveDefinition(base) == base)
        }
    }

    /// Blank fields in a saved override mean "no change to this field",
    /// not "clear it" — otherwise setting only the command would leave a
    /// server launched with zero arguments.
    @Test func aPartialOverrideOnlyReplacesWhatItSets() {
        withCleanDefaults {
            let base = LSPServerRegistry.server(forLanguage: "kotlin")!
            var override = LSPServerOverride()
            override.command = "/custom/kotlin-language-server"
            LSPServerOverrideStore.set(override, for: base.command)

            let effective = LSPCenter.effectiveDefinition(base)
            #expect(effective.command == "/custom/kotlin-language-server")
            #expect(effective.arguments == base.arguments)
            #expect(effective.languageID == base.languageID)
        }
    }

    /// Arguments are re-tokenized the same way the registry itself stores
    /// them — one string per element, not a single packed string handed to
    /// `Process`.
    @Test func overriddenArgumentsAreSplitIntoTokens() {
        withCleanDefaults {
            let base = LSPServerRegistry.server(forLanguage: "vue")!
            var override = LSPServerOverride()
            override.arguments = "--stdio --log verbose"
            LSPServerOverrideStore.set(override, for: base.command)

            let effective = LSPCenter.effectiveDefinition(base)
            #expect(effective.arguments == ["--stdio", "--log", "verbose"])
        }
    }

    /// The one this suite most needed and did not have.
    ///
    /// `effectiveDefinition` rebuilds the definition from a literal, so a
    /// field left out of that literal silently reverts to its default — and
    /// for `origin` the default is `.builtIn`, which is the trust gate
    /// answering "yes" without asking. A contributed server whose command
    /// happens to have an override entry would then launch with no prompt at
    /// all: the whole control bypassed by an omission nobody would see in
    /// review. The comment above that literal says a test pins it; this is
    /// that test.
    @Test func anOverrideDoesNotLaunderAContributedServerIntoABuiltInOne() {
        withCleanDefaults {
            let provenance = ExtensionProvenance(
                extensionID: "acme.elixir",
                digest: "aa11",
                manifestPath: "/Users/x/.config/phantom/extensions/acme.elixir/extension.json",
                scope: .user
            )
            let contributed = LSPServerDefinition(
                languageID: "elixir",
                displayName: "Elixir",
                command: "elixir-ls",
                arguments: ["--stdio"],
                installHint: "brew install elixir-ls",
                origin: .manifest(provenance)
            )

            var override = LSPServerOverride()
            override.command = "/custom/elixir-ls"
            LSPServerOverrideStore.set(override, for: contributed.command)

            let effective = LSPCenter.effectiveDefinition(contributed)
            #expect(effective.command == "/custom/elixir-ls")
            #expect(effective.origin == .manifest(provenance))

            /// Stated as the thing that actually matters: the gate still has
            /// something to ask about.
            #expect(
                LanguageTrust.verdict(
                    for: LanguageTrust.Subject(
                        origin: effective.origin,
                        digest: provenance.digest,
                        command: effective.command,
                        resolvedPath: "/custom/elixir-ls",
                        workspaceRoot: "/Users/x/project"
                    ),
                    record: nil
                ) == .ask(.firstRun)
            )
        }
    }

    /// The override is keyed by the *default* command, so it applies
    /// equally to every language id that shares one binary.
    @Test func anOverrideAppliesToEveryLanguageSharingTheBinary() {
        withCleanDefaults {
            let typescript = LSPServerRegistry.server(forLanguage: "typescript")!
            let javascript = LSPServerRegistry.server(forLanguage: "javascript")!
            #expect(typescript.command == javascript.command)

            var override = LSPServerOverride()
            override.command = "/custom/typescript-language-server"
            LSPServerOverrideStore.set(override, for: typescript.command)

            #expect(LSPCenter.effectiveDefinition(typescript).command == "/custom/typescript-language-server")
            #expect(LSPCenter.effectiveDefinition(javascript).command == "/custom/typescript-language-server")
        }
    }
}
