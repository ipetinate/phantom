import Foundation
@testable import Ghostty
import Testing

/// Precedence, and what happens when two things want the same file type.
///
/// The rule under test is the one the whole extension design rests on:
/// **compiled registry > user extension > bundled extension**, with
/// promotion — a click in Settings, never something a file can ask for — as
/// the only way past it. Copying a manifest into a directory must not change
/// a language the user already had.
///
/// The second rule is duller and matters as much: ties are broken by
/// directory name, lexicographically. Which manifest wins is nearly
/// arbitrary; that it is the *same* one on every machine is not. Resolution
/// that depended on `contentsOfDirectory` order would be a bug that
/// reproduces for one person and not the next.
struct LanguageCatalogTests {
    private func manifest(
        directory: String,
        id: String,
        scope: LanguageManifest.Scope = .user,
        languages: String
    ) -> LanguageManifest {
        let root = URL(fileURLWithPath: "/tmp/phantom-catalog").appendingPathComponent(directory)
        let json = #"""
        {
          "schemaVersion": 1,
          "id": "\#(id)",
          "name": "\#(id)",
          "version": "1.0.0",
          "publisher": "acme",
          "contributes": { "languages": [\#(languages)] }
        }
        """#
        return LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: scope
        )!
    }

    private static let elixir = #"""
    {
      "languageId": "elixir",
      "name": "Elixir",
      "extensions": ["ex", "exs"],
      "fileNames": ["mix.lock"],
      "keywords": ["def", "end"],
      "lineComment": "#",
      "server": { "command": "elixir-ls" }
    }
    """#

    // MARK: The registry wins

    /// The invariant the design is for: an extension that claims `ts` loads,
    /// is listed — a silently missing extension is a support question — and
    /// changes nothing.
    @Test func aManifestClaimingTypeScriptDoesNotDisplaceTheBuiltIn() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(
                directory: "acme.fakets",
                id: "acme.fakets",
                languages: #"""
                {
                  "languageId": "faketypescript",
                  "extensions": ["ts"],
                  "server": { "command": "evil-ls" }
                }
                """#
            )],
            promotions: []
        )

        let contributed = try #require(catalog.contributed.first)
        #expect(contributed.resolution == .shadowed(by: .builtIn, claim: "ext:ts"))
        #expect(!contributed.isActive)
        #expect(contributed.serverDefinition == nil)

        #expect(catalog.entries.count == 1)
        #expect(catalog.contribution(forFileName: "main.ts") == nil)
        #expect(LSPServerRegistry.server(forPath: "main.ts")?.command
            == "typescript-language-server")
    }

    /// The registry is not the only compiled-in table that owns file types.
    /// `.svelte` has no language server here, but the highlighter knows it,
    /// and taking it away would still change something the user did not ask
    /// to change.
    @Test func theHighlightersOwnTableCountsAsBuiltIn() {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(
                directory: "acme.svelte",
                id: "acme.svelte",
                languages: #"{ "languageId": "mysvelte", "extensions": ["svelte"] }"#
            )],
            promotions: []
        )
        #expect(catalog.contributed.first?.resolution == .shadowed(by: .builtIn, claim: "ext:svelte"))
    }

    /// File names are compared case-insensitively, so `makefile` has to
    /// count as taken even though the compiled-in table spells it
    /// `Makefile`.
    @Test func aBuiltInFileNameIsOwnedRegardlessOfCase() {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(
                directory: "acme.make",
                id: "acme.make",
                languages: #"{ "languageId": "mymake", "fileNames": ["Makefile"] }"#
            )],
            promotions: []
        )
        #expect(catalog.contributed.first?.resolution
            == .shadowed(by: .builtIn, claim: "name:makefile"))
    }

    /// A language id the registry already has is taken even when the
    /// extensions differ: the id is what a `didOpen` carries and what the
    /// per-language settings are keyed by.
    @Test func aBuiltInLanguageIDIsOwned() {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(
                directory: "acme.kotlin",
                id: "acme.kotlin",
                languages: #"{ "languageId": "kotlin", "extensions": ["ktx"] }"#
            )],
            promotions: []
        )
        #expect(catalog.contributed.first?.resolution
            == .shadowed(by: .builtIn, claim: "lang:kotlin"))
    }

    // MARK: A language nobody had

    @Test func aLanguageNothingElseClaimsIsActive() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(
                directory: "acme.elixir",
                id: "acme.elixir",
                languages: Self.elixir
            )],
            promotions: []
        )

        let contributed = try #require(catalog.contributed.first)
        #expect(contributed.isActive)
        #expect(catalog.contribution(forFileName: "app.ex")?.id == contributed.id)
        #expect(catalog.contribution(forFileName: "app.exs")?.id == contributed.id)
        #expect(catalog.contribution(forFileName: "mix.lock")?.id == contributed.id)
        #expect(catalog.contribution(forFileName: "app.ts") == nil)

        let definition = try #require(contributed.serverDefinition)
        #expect(definition.command == "elixir-ls")
        #expect(definition.languageID == "elixir")
        #expect(definition.origin == .manifest(contributed.provenance))
    }

    /// A name is a more specific statement than an extension, which is the
    /// order `LSPServerRegistry.languageID(forPath:)` already uses.
    @Test func aFileNameBeatsAnExtension() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(
                    directory: "a.byname",
                    id: "a.byname",
                    languages: #"{ "languageId": "lockfile", "fileNames": ["mix.lock"] }"#
                ),
                manifest(
                    directory: "b.byext",
                    id: "b.byext",
                    languages: #"{ "languageId": "locky", "extensions": ["lock"] }"#
                ),
            ],
            promotions: []
        )
        #expect(catalog.contribution(forFileName: "mix.lock")?.language.languageID == "lockfile")
        #expect(catalog.contribution(forFileName: "other.lock")?.language.languageID == "locky")
    }

    // MARK: Two extensions, one file type

    /// The manifests are handed over in the order that would win if
    /// discovery order decided anything, which is the point.
    @Test func twoExtensionsClaimingTheSameTypeResolveLexicographically() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(directory: "zeta.elixir", id: "zeta.elixir", languages: Self.elixir),
                manifest(directory: "alpha.elixir", id: "alpha.elixir", languages: Self.elixir),
            ],
            promotions: []
        )

        #expect(catalog.contributed.count == 2)
        let winner = try #require(catalog.contributed.first)
        let loser = try #require(catalog.contributed.last)

        #expect(winner.provenance.extensionID == "alpha.elixir")
        #expect(winner.isActive)
        #expect(loser.provenance.extensionID == "zeta.elixir")
        #expect(loser.resolution == .shadowed(by: .extensionID("alpha.elixir"), claim: "lang:elixir"))
        #expect(catalog.contribution(forFileName: "app.ex")?.provenance.extensionID
            == "alpha.elixir")
    }

    /// The user's directory outranks the bundle, whatever the names are.
    @Test func aUserExtensionOutranksABundledOne() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(
                    directory: "aaa.elixir",
                    id: "aaa.elixir",
                    scope: .bundled,
                    languages: Self.elixir
                ),
                manifest(
                    directory: "zzz.elixir",
                    id: "zzz.elixir",
                    scope: .user,
                    languages: Self.elixir
                ),
            ],
            promotions: []
        )
        #expect(catalog.contributed.first?.provenance.extensionID == "zzz.elixir")
        #expect(catalog.contributed.first?.isActive == true)
        #expect(catalog.contributed.last?.resolution
            == .shadowed(by: .extensionID("zzz.elixir"), claim: "lang:elixir"))
    }

    /// Shadowing is all-or-nothing across a contribution's claims. Half a
    /// language — one extension highlighted, its neighbour not — is not
    /// something a user could be expected to work out.
    @Test func aContributionIsShadowedWholeRatherThanPerClaim() {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(
                directory: "acme.mixed",
                id: "acme.mixed",
                languages: #"{ "languageId": "mixed", "extensions": ["neverseen", "ts"] }"#
            )],
            promotions: []
        )
        #expect(catalog.contributed.first?.isActive == false)
        #expect(catalog.contribution(forFileName: "a.neverseen") == nil)
    }

    // MARK: Promotion

    @Test func promotionMovesAContributionAheadOfTheRegistry() throws {
        let claiming = manifest(
            directory: "acme.fakets",
            id: "acme.fakets",
            languages: #"""
            { "languageId": "faketypescript", "extensions": ["ts"], "keywords": ["def"] }
            """#
        )

        let before = LanguageCatalog.resolve(manifests: [claiming], promotions: [])
        #expect(before.contributed.first?.isActive == false)

        let after = LanguageCatalog.resolve(
            manifests: [claiming],
            promotions: [LanguagePromotionStore.key(
                extensionID: "acme.fakets",
                languageID: "faketypescript"
            )]
        )
        #expect(after.contributed.first?.isActive == true)
        #expect(after.contribution(forFileName: "main.ts")?.language.languageID
            == "faketypescript")
    }

    /// A promotion covers one language of one extension — promoting the
    /// Elixir half of a pack does not promote whatever else it claimed.
    @Test func promotionIsPerLanguageAndNotPerExtension() throws {
        let pack = manifest(
            directory: "acme.pack",
            id: "acme.pack",
            languages: #"""
            { "languageId": "faketypescript", "extensions": ["ts"] },
            { "languageId": "fakego", "extensions": ["go"] }
            """#
        )

        let catalog = LanguageCatalog.resolve(
            manifests: [pack],
            promotions: [LanguagePromotionStore.key(
                extensionID: "acme.pack",
                languageID: "faketypescript"
            )]
        )

        let byID = Dictionary(
            uniqueKeysWithValues: catalog.contributed.map { ($0.language.languageID, $0) }
        )
        #expect(byID["faketypescript"]?.isActive == true)
        #expect(byID["fakego"]?.isActive == false)
    }

    // MARK: Scanning

    /// A directory with no manifest, and a loose file beside the extension
    /// directories, are both skipped rather than counted.
    @Test func scanningADirectoryReadsEveryExtensionInIt() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-catalog-" + UUID().uuidString)
        let user = base.appendingPathComponent("user")
        let bundled = base.appendingPathComponent("bundled")
        defer { try? FileManager.default.removeItem(at: base) }

        func write(_ id: String, in directory: URL) throws {
            let root = directory.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let json = #"""
            {
              "id": "\#(id)",
              "contributes": {
                "languages": [{ "languageId": "\#(id.replacingOccurrences(of: ".", with: "-"))" }]
              }
            }
            """#
            try Data(json.utf8).write(to: root.appendingPathComponent(LanguageManifest.fileName))
        }

        try write("acme.one", in: user)
        try write("acme.two", in: user)
        try write("phantom.bundled", in: bundled)

        try FileManager.default.createDirectory(
            at: user.appendingPathComponent("empty"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: user.appendingPathComponent("stray.json"))

        let catalog = LanguageCatalog.load(bundled: bundled, user: user, promotions: [])

        #expect(catalog.entries.map(\.id) == ["acme.one", "acme.two", "phantom.bundled"])
        #expect(catalog.contributed.count == 3)
        /// Computed outside the macro: `allSatisfy` is `rethrows`, and inside
        /// `#expect`'s expansion Swift cannot prove the closure does not
        /// throw, so the call reads as throwing in a test that is not.
        let allActive = catalog.contributed.allSatisfy(\.isActive)
        #expect(allActive)
    }

    @Test func aMissingDirectoryIsNotAnError() {
        let missing = URL(fileURLWithPath: "/tmp/phantom-does-not-exist-" + UUID().uuidString)
        let catalog = LanguageCatalog.load(bundled: nil, user: missing, promotions: [])
        #expect(catalog == .empty)
    }
}
