import Foundation
@testable import Ghostty
import Testing

/// The trust model, as a function.
///
/// Nothing here goes near a `Process`, a window or `UserDefaults` — that is
/// the reason `LanguageTrust.verdict(for:record:)` takes the resolved path
/// and the workspace root as values instead of looking them up. A gate whose
/// policy can only be exercised by launching something is a gate nobody
/// tests.
struct LanguageTrustTests {
    private static let provenance = ExtensionProvenance(
        extensionID: "acme.elixir",
        digest: "aa11",
        manifestPath: "/Users/x/.config/phantom/extensions/acme.elixir/extension.json",
        scope: .user
    )

    private func subject(
        digest: String = "aa11",
        command: String = "elixir-ls",
        resolvedPath: String = "/opt/homebrew/bin/elixir-ls",
        workspaceRoot: String? = "/Users/x/project",
        provenance: ExtensionProvenance = LanguageTrustTests.provenance
    ) -> LanguageTrust.Subject {
        LanguageTrust.Subject(
            origin: .manifest(provenance),
            digest: digest,
            command: command,
            resolvedPath: resolvedPath,
            workspaceRoot: workspaceRoot
        )
    }

    private func record(
        decision: LanguageTrustRecord.Decision = .allowed,
        digest: String = "aa11",
        command: String = "elixir-ls",
        resolvedPath: String = "/opt/homebrew/bin/elixir-ls",
        manifestPath: String = LanguageTrustTests.provenance.manifestPath,
        recordVersion: Int = LanguageTrustStore.currentRecordVersion
    ) -> LanguageTrustRecord {
        LanguageTrustRecord(
            recordVersion: recordVersion,
            digest: digest,
            command: command,
            resolvedPath: resolvedPath,
            manifestPath: manifestPath,
            decision: decision,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: The compiled-in case

    /// The registry is not asked about. This is also what makes the field on
    /// `LSPServerDefinition` safe to default: a definition that never says
    /// where it came from is treated as one of ours, and all twenty-five of
    /// ours are.
    @Test func aBuiltInServerIsAllowedWithoutAsking() {
        let builtIn = LanguageTrust.Subject(
            origin: .builtIn,
            digest: "",
            command: "typescript-language-server",
            resolvedPath: "/usr/local/bin/typescript-language-server",
            workspaceRoot: "/Users/x/project"
        )
        #expect(LanguageTrust.verdict(for: builtIn, record: nil) == .allow)
    }

    // MARK: First run and remembering

    @Test func anUnknownExtensionIsAskedAbout() {
        #expect(LanguageTrust.verdict(for: subject(), record: nil) == .ask(.firstRun))
    }

    @Test func anApprovalForTheseExactBytesIsHonoured() {
        #expect(LanguageTrust.verdict(for: subject(), record: record()) == .allow)
    }

    /// A prompt that reappears on every `.ex` file is a prompt that gets
    /// approved by accident, so an unchanged approval is not re-asked.
    @Test func anApprovalIsNotReAskedForASecondFile() {
        let first = LanguageTrust.verdict(for: subject(), record: record())
        let second = LanguageTrust.verdict(for: subject(), record: record())
        #expect(first == .allow)
        #expect(second == .allow)
    }

    // MARK: Invalidation

    @Test func changedManifestBytesInvalidateAnApproval() {
        #expect(
            LanguageTrust.verdict(for: subject(digest: "bb22"), record: record(digest: "aa11"))
                == .ask(.manifestChanged)
        )
    }

    /// Compared separately from the digest so the prompt can say *what*
    /// changed — "it now wants to run something else" is a different
    /// sentence from "the file changed", and the user needs the first one.
    @Test func aChangedCommandInvalidatesAnApprovalAndSaysWhat() {
        #expect(
            LanguageTrust.verdict(
                for: subject(command: "elixir-ls-next"),
                record: record(command: "elixir-ls")
            ) == .ask(.commandChanged(previous: "elixir-ls"))
        )
    }

    /// Moving the manifest invalidates: the record names where the file was,
    /// and an approval does not follow it to a new home.
    @Test func aMovedManifestInvalidatesAnApproval() {
        #expect(
            LanguageTrust.verdict(
                for: subject(),
                record: record(manifestPath: "/somewhere/else/extension.json")
            ) == .ask(.manifestMoved(previous: "/somewhere/else/extension.json"))
        )
    }

    /// A *path* that has moved, not a binary whose contents changed. Pinning
    /// the contents would re-prompt after every `brew upgrade` and train the
    /// user to click through — worse than not checking. A path that moved
    /// usually means something new is earlier on `PATH`, which is the case
    /// worth interrupting for.
    @Test func aCommandThatNowResolvesElsewhereInvalidatesAnApproval() {
        #expect(
            LanguageTrust.verdict(
                for: subject(resolvedPath: "/usr/local/bin/elixir-ls"),
                record: record(resolvedPath: "/opt/homebrew/bin/elixir-ls")
            ) == .ask(.commandPathChanged(previous: "/opt/homebrew/bin/elixir-ls"))
        )
    }

    // MARK: Refusal

    @Test func aRefusalIsRemembered() {
        #expect(
            LanguageTrust.verdict(for: subject(), record: record(decision: .refused))
                == .deny(.refusedByUser(at: Date(timeIntervalSince1970: 1_700_000_000)))
        )
    }

    /// Deliberately *not* re-asked when the manifest changes. Otherwise
    /// touching the file would earn another prompt, and an author who can
    /// prompt at will only has to wait for a distracted moment.
    @Test func aRefusalSurvivesTheManifestChanging() {
        #expect(
            LanguageTrust.verdict(
                for: subject(digest: "bb22"),
                record: record(decision: .refused, digest: "aa11")
            ) == .deny(.refusedByUser(at: Date(timeIntervalSince1970: 1_700_000_000)))
        )
    }

    // MARK: Hardenings, which no answer overrides

    /// Plenty of shells put `./node_modules/.bin` on `PATH`, so a manifest
    /// can name an innocent command and rely on a freshly-cloned repository
    /// to supply it. Approving the name would approve whatever the repo
    /// shipped, so this is refused rather than asked — and refused even for
    /// an extension the user already approved.
    @Test func aCommandResolvingInsideTheWorkspaceIsRefusedEvenWhenApproved() {
        let inside = "/Users/x/project/node_modules/.bin/elixir-ls"
        #expect(
            LanguageTrust.verdict(
                for: subject(resolvedPath: inside),
                record: record(resolvedPath: inside)
            ) == .deny(.commandInsideWorkspace(path: inside))
        )
    }

    @Test func aCommandOutsideTheWorkspaceIsFine() {
        #expect(LanguageTrust.verdict(for: subject(), record: record()) == .allow)
    }

    /// A workspace of `/` is not a repository that shipped anything, and
    /// treating it as one would deny every server for a loose file.
    @Test func traversalCannotHideAWorkspacePath() {
        let sneaky = "/Users/x/project/../project/node_modules/.bin/elixir-ls"
        #expect(LanguageTrust.isInside(sneaky, root: "/Users/x/project"))
        #expect(!LanguageTrust.isInside("/Users/x/project-other/bin/ls", root: "/Users/x/project"))
        #expect(!LanguageTrust.isInside("/usr/bin/ls", root: "/"))
    }

    /// Already refused at parse time. Checked again because this is the last
    /// point before a process exists, and a defence that lives at one layer
    /// is one refactor from living at none.
    @Test func aShellShapedCommandIsRefusedAtTheGateToo() {
        #expect(
            LanguageTrust.verdict(
                for: subject(command: "elixir-ls; rm -rf ~"),
                record: record(command: "elixir-ls; rm -rf ~")
            ) == .deny(.unsafeCommand)
        )
    }

    /// A bundled manifest is trusted by where it is, which assumes the app's
    /// own `Resources` are not writable — true of a signed, installed app
    /// and **false of a local ad-hoc build**.
    @Test func aBundledManifestIsTrustedByOrigin() {
        let bundled = ExtensionProvenance(
            extensionID: "phantom.elixir",
            digest: "cc33",
            manifestPath: "/Applications/Phantom.app/Contents/Resources/extensions/x/extension.json",
            scope: .bundled
        )
        #expect(LanguageTrust.verdict(for: subject(provenance: bundled), record: nil) == .allow)
    }

    // MARK: The record

    @Test func theRecordCapturesEverythingTheVerdictCompares() {
        let written = LanguageTrust.record(
            for: subject(),
            decision: .allowed,
            at: Date(timeIntervalSince1970: 42)
        )
        #expect(written.recordVersion == LanguageTrustStore.currentRecordVersion)
        #expect(written.digest == "aa11")
        #expect(written.command == "elixir-ls")
        #expect(written.resolvedPath == "/opt/homebrew/bin/elixir-ls")
        #expect(written.manifestPath == Self.provenance.manifestPath)
        #expect(written.decision == .allowed)
        #expect(written.decidedAt == Date(timeIntervalSince1970: 42))

        #expect(LanguageTrust.verdict(for: subject(), record: written) == .allow)
    }
}

/// The prompt's text, which is the whole of the control.
///
/// Only the strings are tested. Presentation is not: the test host has no
/// event loop, and anything reaching `runModal` or `orderFront` hangs the
/// entire suite — the trap documented in `CodeHoverPersistenceTests`.
struct LanguageTrustAlertTests {
    private func request(
        extensionName: String = "Elixir",
        publisher: String = "acme",
        command: String = "elixir-ls",
        arguments: [String] = ["--stdio"],
        change: LanguageTrust.Change = .firstRun
    ) -> LanguageTrustAlert.Request {
        LanguageTrustAlert.Request(
            extensionName: extensionName,
            extensionID: "acme.elixir",
            publisher: publisher,
            extensionVersion: "1.2.0",
            languageName: "Elixir",
            command: command,
            arguments: arguments,
            resolvedPath: "/opt/homebrew/bin/elixir-ls",
            manifestPath: "/Users/x/.config/phantom/extensions/acme.elixir/extension.json",
            change: change
        )
    }

    /// The finding this test exists for: without escaping, a right-to-left
    /// override in a manifest's `name` reverses the text after it, and the
    /// dialog can be made to display a command other than the one being
    /// approved.
    @Test func aNameWithABidirectionalOverrideComesBackEscaped() {
        let message = LanguageTrustAlert.messageText(
            for: request(extensionName: "Elixir\u{202E}gnp yb")
        )
        #expect(!message.unicodeScalars.contains("\u{202E}"))
        #expect(message.contains("\\u{202E}"))
    }

    /// A newline would add a line to the dialog, and a line the manifest
    /// controls can restate the command.
    @Test func aNewlineInAManifestStringCannotAddALine() {
        let detail = LanguageTrustAlert.detailText(
            for: request(command: "elixir-ls", arguments: ["--stdio\nCommand: /bin/sh"])
        )
        #expect(!detail.contains("\nCommand: /bin/sh"))
        #expect(detail.contains("\\u{A}"))
    }

    @Test func everyPartOfTheDetailBlockIsEscaped() {
        for scalar in ["\u{202E}", "\u{200B}", "\u{2028}", "\u{0}", "\u{FEFF}"] {
            let detail = LanguageTrustAlert.detailText(for: request(command: "elixir\(scalar)-ls"))
            let dangerous = scalar.unicodeScalars.first!
            #expect(!detail.unicodeScalars.contains(dangerous), "\(scalar) survived")
        }
    }

    @Test func theDetailBlockNamesWhatWillActuallyRun() {
        let detail = LanguageTrustAlert.detailText(for: request())
        #expect(detail.contains("elixir-ls --stdio"))
        #expect(detail.contains("/opt/homebrew/bin/elixir-ls"))
        #expect(detail.contains("extensions/acme.elixir/extension.json"))
        #expect(detail.contains("acme.elixir"))
    }

    /// Saying so is the point: the app is not sandboxed, and an approved
    /// server has everything the person running Phantom has.
    @Test func theProseSaysItRunsAsTheUser() {
        let text = LanguageTrustAlert.informativeText(for: request())
        #expect(text.contains("runs as you"))
        #expect(text.contains("keychain"))
        #expect(text.contains("asks again"))
        #expect(text.contains("Settings"))
    }

    @Test func aRepeatPromptSaysWhyItIsBack() {
        #expect(LanguageTrustAlert.changeText(for: .firstRun) == nil)
        #expect(LanguageTrustAlert.changeText(for: .manifestChanged)?.contains("changed") == true)
        #expect(
            LanguageTrustAlert.changeText(for: .commandChanged(previous: "old-ls"))?
                .contains("old-ls") == true
        )
        #expect(
            LanguageTrustAlert.changeText(for: .manifestMoved(previous: "/old/path"))?
                .contains("/old/path") == true
        )
    }

    @Test func anUnnamedPublisherIsNamedAsUnidentifiedRatherThanLeftBlank() {
        let text = LanguageTrustAlert.informativeText(for: request(publisher: ""))
        #expect(text.contains("unidentified publisher"))
    }
}

/// Trust and promotion, saved and read back.
///
/// Serialized, and in one suite with everything else that touches these two
/// keys, for the reason `LSPServerOverrideStoreTests` spells out: these tests
/// save and restore the real defaults a locally-running Phantom reads, and
/// interleaved save/restore pairs from concurrent suites put back the wrong
/// snapshot.
@Suite(.serialized)
struct LanguageTrustStoreTests {
    private func withCleanDefaults(_ body: () -> Void) {
        let keys = [LanguageTrustStore.defaultsKey, LanguagePromotionStore.defaultsKey]
        let stored = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, stored) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    private func record(
        decision: LanguageTrustRecord.Decision = .allowed,
        recordVersion: Int = LanguageTrustStore.currentRecordVersion
    ) -> LanguageTrustRecord {
        LanguageTrustRecord(
            recordVersion: recordVersion,
            digest: "aa11",
            command: "elixir-ls",
            resolvedPath: "/opt/homebrew/bin/elixir-ls",
            manifestPath: "/Users/x/.config/phantom/extensions/acme.elixir/extension.json",
            decision: decision,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func withNothingStoredThereIsNoRecord() {
        withCleanDefaults {
            #expect(LanguageTrustStore.record(for: "acme.elixir") == nil)
        }
    }

    @Test func aSavedRecordReadsBackAsIs() {
        withCleanDefaults {
            let saved = record()
            LanguageTrustStore.set(saved, for: "acme.elixir")
            #expect(LanguageTrustStore.record(for: "acme.elixir") == saved)
        }
    }

    /// A record this build cannot decode reads as **absent**, which means
    /// the user is asked again. Absent must never mean allowed — so the
    /// verdict for one is asserted here too, not only the store's answer.
    @Test func aRecordFromALaterVersionReadsAsAbsent() {
        withCleanDefaults {
            LanguageTrustStore.set(
                record(recordVersion: LanguageTrustStore.currentRecordVersion + 1),
                for: "acme.elixir"
            )
            #expect(LanguageTrustStore.record(for: "acme.elixir") == nil)

            let subject = LanguageTrust.Subject(
                origin: .manifest(ExtensionProvenance(
                    extensionID: "acme.elixir",
                    digest: "aa11",
                    manifestPath: "/x/extension.json",
                    scope: .user
                )),
                digest: "aa11",
                command: "elixir-ls",
                resolvedPath: "/opt/homebrew/bin/elixir-ls",
                workspaceRoot: nil
            )
            #expect(
                LanguageTrust.verdict(
                    for: subject,
                    record: LanguageTrustStore.record(for: "acme.elixir")
                ) == .ask(.firstRun)
            )
        }
    }

    @Test func garbageInTheKeyIsNotARecord() {
        withCleanDefaults {
            UserDefaults.standard.set(
                Data("not json".utf8),
                forKey: LanguageTrustStore.defaultsKey
            )
            #expect(LanguageTrustStore.record(for: "acme.elixir") == nil)
            #expect(LanguageTrustStore.all.isEmpty)
        }
    }

    @Test func recordsForDifferentExtensionsAreIndependent() {
        withCleanDefaults {
            LanguageTrustStore.set(record(decision: .allowed), for: "acme.elixir")
            LanguageTrustStore.set(record(decision: .refused), for: "other.gleam")

            #expect(LanguageTrustStore.record(for: "acme.elixir")?.decision == .allowed)
            #expect(LanguageTrustStore.record(for: "other.gleam")?.decision == .refused)
        }
    }

    /// The only way back from a refusal, and it is reachable from Settings
    /// alone — never from the prompt and never from an extension.
    @Test func forgettingClearsARefusal() {
        withCleanDefaults {
            LanguageTrustStore.set(record(decision: .refused), for: "acme.elixir")
            LanguageTrustStore.forget("acme.elixir")
            #expect(LanguageTrustStore.record(for: "acme.elixir") == nil)
        }
    }

    /// An extension with no usable id has nowhere for a decision to live,
    /// and writing one under an empty key would be a decision that applies
    /// to every such extension at once.
    @Test func anEmptyIdentityIsNotWritable() {
        withCleanDefaults {
            LanguageTrustStore.set(record(), for: "")
            #expect(LanguageTrustStore.all.isEmpty)
        }
    }

    @Test func rememberWritesUnderTheProvenanceIdentity() {
        withCleanDefaults {
            let subject = LanguageTrust.Subject(
                origin: .manifest(ExtensionProvenance(
                    extensionID: "acme.elixir",
                    digest: "aa11",
                    manifestPath: "/x/extension.json",
                    scope: .user
                )),
                digest: "aa11",
                command: "elixir-ls",
                resolvedPath: "/opt/homebrew/bin/elixir-ls",
                workspaceRoot: nil
            )

            LanguageTrustStore.remember(.refused, for: subject)

            let stored = LanguageTrustStore.record(for: "acme.elixir")
            #expect(stored?.decision == .refused)
            #expect(stored?.manifestPath == "/x/extension.json")
        }
    }

    // MARK: Promotion

    @Test func promotionsRoundTripAndAreScopedToOneLanguage() {
        withCleanDefaults {
            #expect(!LanguagePromotionStore.isPromoted(
                extensionID: "acme.pack",
                languageID: "elixir"
            ))

            LanguagePromotionStore.setPromoted(
                true,
                extensionID: "acme.pack",
                languageID: "elixir"
            )

            #expect(LanguagePromotionStore.isPromoted(
                extensionID: "acme.pack",
                languageID: "elixir"
            ))
            #expect(!LanguagePromotionStore.isPromoted(
                extensionID: "acme.pack",
                languageID: "gleam"
            ))

            LanguagePromotionStore.setPromoted(
                false,
                extensionID: "acme.pack",
                languageID: "elixir"
            )
            #expect(LanguagePromotionStore.all.isEmpty)
        }
    }
}
