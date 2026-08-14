import Foundation
@testable import Ghostty
import Testing

/// `extension.json`, parsed the way a file we did not write has to be
/// parsed.
///
/// Every test here is written as raw JSON text rather than as a dictionary,
/// on purpose: the digest is taken over the bytes, and a fixture built from
/// a `[String: Any]` would never exercise the path a file actually takes.
///
/// The shape of the suite is `IconThemeTests`': a defect costs the manifest
/// one field and never the load, and the cases that matter are the hostile
/// ones. In all of them the invariant is the same — **the language still
/// loads, only the server falls away.** An extension the user has not
/// approved is not a broken editor.
struct LanguageManifestTests {
    private static let root = URL(fileURLWithPath: "/tmp/phantom-tests/acme.elixir")

    private func parse(
        _ json: String,
        root: URL = LanguageManifestTests.root,
        scope: LanguageManifest.Scope = .user
    ) -> LanguageManifest? {
        LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: scope
        )
    }

    /// The manifest from the design, so the happy path is one fixture the
    /// rest of the suite can be read against.
    private static let elixir = #"""
    {
      "schemaVersion": 1,
      "id": "acme.elixir",
      "name": "Elixir",
      "version": "1.2.0",
      "publisher": "acme",
      "contributes": {
        "languages": [{
          "languageId": "elixir",
          "name": "Elixir",
          "extensions": ["ex", "exs"],
          "fileNames": ["mix.lock"],
          "keywords": ["def", "defmodule", "do", "end"],
          "lineComment": "#",
          "blockComment": ["\"\"\"", "\"\"\""],
          "category": "script",
          "server": {
            "command": "elixir-ls",
            "args": ["--stdio"],
            "installHint": "brew install elixir-ls",
            "documentationURL": "https://github.com/elixir-lsp/elixir-ls"
          }
        }]
      }
    }
    """#

    // MARK: The envelope

    @Test func theEnvelopeParses() throws {
        let manifest = try #require(parse(Self.elixir))

        #expect(manifest.id == "acme.elixir")
        #expect(manifest.name == "Elixir")
        #expect(manifest.version == "1.2.0")
        #expect(manifest.publisher == "acme")
        #expect(manifest.eligibility == .eligible)
        #expect(manifest.isUsable)
        #expect(manifest.badge == nil)

        let language = try #require(manifest.languages.first)
        #expect(language.languageID == "elixir")
        #expect(language.fileExtensions == ["ex", "exs"])
        #expect(language.fileNames == ["mix.lock"])
        #expect(language.keywords == ["def", "defmodule", "do", "end"])
        #expect(language.lineComment == "#")
        let tripleQuote = "\"\"\""
        #expect(language.blockComment == LanguageSyntax.BlockComment(
            open: tripleQuote,
            close: tripleQuote
        ))
        #expect(language.category == .script)
        #expect(language.server?.command == "elixir-ls")
        #expect(language.server?.arguments == ["--stdio"])
        #expect(language.serverRejection == nil)
    }

    /// The digest is over the bytes, so re-indenting the same manifest is a
    /// different manifest — which is the point: an approval is given for a
    /// file, and a file that has been rewritten is not that file.
    @Test func theDigestFollowsTheBytesAndNotTheMeaning() throws {
        let compact = #"{"id":"a.b","contributes":{"languages":[]}}"#
        let spaced = #"{ "id" : "a.b" , "contributes" : { "languages" : [ ] } }"#

        let first = try #require(parse(compact))
        let second = try #require(parse(spaced))

        #expect(first.id == second.id)
        #expect(first.digest != second.digest)
        #expect(first.digest.count == 64)
    }

    /// The directory name shows up as the display name and never as the
    /// identity — an empty `id` is what turns the server half off.
    @Test func anEmptyManifestParsesAndIsUnusable() throws {
        let manifest = try #require(parse("{}"))

        #expect(manifest.languages.isEmpty)
        #expect(!manifest.isUsable)
        #expect(manifest.eligibility == .unidentified)
        #expect(manifest.badge == "Missing extension id")
        #expect(manifest.name == "acme.elixir")
        #expect(manifest.id.isEmpty)
    }

    @Test func somethingThatIsNotAJSONObjectDoesNotLoad() {
        #expect(parse("[]") == nil)
        #expect(parse("not json at all") == nil)
        #expect(parse("") == nil)
    }

    /// A manifest is a language description. One measured in megabytes is a
    /// parse this app pays for at launch, so the size is checked on the
    /// bytes before a parser ever sees them.
    @Test func aTwoMegabyteManifestIsRefusedWhole() {
        let padding = String(repeating: "a", count: 2 * 1024 * 1024)
        let json = #"{"id":"a.b","name":"\#(padding)"}"#
        #expect(Data(json.utf8).count > 2 * 1024 * 1024)
        #expect(parse(json) == nil)
    }

    /// Keys from a later schema are counted, not rejected — that count is
    /// what lets Settings say how much of the file this build ignored, and
    /// the ignoring is what makes forward compatibility work at all.
    @Test func unknownFieldsAreIgnoredAndCounted() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "engines": { "phantom": ">=2" },
          "activationEvents": ["onLanguage:elixir"],
          "contributes": {
            "languages": [{ "languageId": "elixir" }],
            "themes": [],
            "commands": []
          }
        }
        """#))

        #expect(manifest.unrecognizedFields == [
            "activationEvents", "contributes.commands", "contributes.themes", "engines",
        ])
        #expect(manifest.languages.count == 1)
    }

    // MARK: Schema version — the asymmetry

    /// The security-relevant call in the format: a schema this build cannot
    /// read keeps the language half and drops the server half. Keywords
    /// cannot hurt anybody; a `command` whose meaning may have changed can.
    @Test func aNewerSchemaKeepsTheLanguageAndDropsTheServer() throws {
        let manifest = try #require(parse(#"""
        {
          "schemaVersion": 2,
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "extensions": ["ex"],
              "keywords": ["def"],
              "server": { "command": "elixir-ls" }
            }]
          }
        }
        """#))

        #expect(manifest.eligibility == .needsNewerApp(declared: "2"))
        #expect(manifest.badge == "Needs a newer Phantom")

        let language = try #require(manifest.languages.first)
        #expect(language.fileExtensions == ["ex"])
        #expect(language.keywords == ["def"])
        #expect(language.server == nil)
        #expect(language.serverRejection == .ineligible(.needsNewerApp(declared: "2")))
    }

    /// A version that is not an integer is not a version this build can
    /// compare against, which is the same situation as a newer one.
    @Test func aSchemaVersionThatIsNotAnIntegerIsTreatedAsNewer() throws {
        for declared in ["\"1\"", "1.5", "true", "null", "[1]"] {
            let manifest = try #require(parse(#"""
            {
              "schemaVersion": \#(declared),
              "id": "acme.elixir",
              "contributes": {
                "languages": [{ "languageId": "elixir", "server": { "command": "elixir-ls" } }]
              }
            }
            """#))
            #expect(manifest.languages.first?.server == nil, "schemaVersion \(declared)")
            #expect(manifest.languages.first?.languageID == "elixir", "schemaVersion \(declared)")
        }
    }

    /// Absent is read as v1: there is no earlier schema for it to mean, and
    /// omitting the key gets an author the strictest rules this build has.
    @Test func anAbsentSchemaVersionIsReadAsTheCurrentOne() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{ "languageId": "elixir", "server": { "command": "elixir-ls" } }]
          }
        }
        """#))
        #expect(manifest.eligibility == .eligible)
        #expect(manifest.languages.first?.server?.command == "elixir-ls")
    }

    /// No identity means nowhere for an approval to live, so there is no
    /// process either — the language still arrives.
    @Test func aManifestWithNoUsableIDContributesNoServer() throws {
        for id in ["", "\"\"", "\"../../etc\"", "\"a/b\"", "\"a..b\"", "\"a b\""] {
            let idField = id.isEmpty ? "" : "\"id\": \(id),"
            let manifest = try #require(parse(#"""
            {
              \#(idField)
              "contributes": {
                "languages": [{
                  "languageId": "elixir",
                  "extensions": ["ex"],
                  "server": { "command": "elixir-ls" }
                }]
              }
            }
            """#))
            #expect(manifest.eligibility == .unidentified, "id \(id)")
            #expect(manifest.languages.first?.server == nil, "id \(id)")
            #expect(manifest.languages.first?.fileExtensions == ["ex"], "id \(id)")
        }
    }

    @Test func anIDWithAPublisherPrefixIsAllowed() throws {
        let manifest = try #require(parse(#"{"id":"acme.elixir-ls_2"}"#))
        #expect(manifest.id == "acme.elixir-ls_2")
    }

    // MARK: Wrong types, right load

    /// A string where an array belonged costs that field. Splitting it would
    /// be guessing at a separator, and the file is not ours to guess about.
    @Test func extensionsGivenAsAStringAreIgnoredAndTheRestStillLoads() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "name": "Elixir",
              "extensions": "ex,exs",
              "keywords": ["def"],
              "server": { "command": "elixir-ls" }
            }]
          }
        }
        """#))

        let language = try #require(manifest.languages.first)
        #expect(language.fileExtensions.isEmpty)
        #expect(language.displayName == "Elixir")
        #expect(language.keywords == ["def"])
        #expect(language.server?.command == "elixir-ls")
    }

    @Test func argsGivenAsAStringAreIgnoredRatherThanSplit() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "server": { "command": "elixir-ls", "args": "--stdio --verbose" }
            }]
          }
        }
        """#))
        #expect(manifest.languages.first?.server?.arguments.isEmpty == true)
    }

    /// Survivors come back lower-cased, de-dotted and de-duplicated.
    @Test func oneBadElementCostsThatElementAndNotTheList() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "extensions": ["ex", 7, null, ".exs", "  ", "EX"]
            }]
          }
        }
        """#))
        #expect(manifest.languages.first?.fileExtensions == ["ex", "exs"])
    }

    @Test func aLanguageWithNoUsableIDIsDroppedAndItsSiblingsSurvive() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.pack",
          "contributes": {
            "languages": [
              { "languageId": "../../etc/passwd", "extensions": ["a"] },
              { "languageId": "with/slash", "extensions": ["b"] },
              { "languageId": "", "extensions": ["c"] },
              { "extensions": ["d"] },
              { "languageId": "elixir", "extensions": ["ex"] }
            ]
          }
        }
        """#))
        #expect(manifest.languages.map(\.languageID) == ["elixir"])
    }

    @Test func theSameLanguageTwiceKeepsTheFirst() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.pack",
          "contributes": {
            "languages": [
              { "languageId": "elixir", "extensions": ["ex"] },
              { "languageId": "elixir", "extensions": ["exs"] }
            ]
          }
        }
        """#))
        #expect(manifest.languages.count == 1)
        #expect(manifest.languages.first?.fileExtensions == ["ex"])
    }

    // MARK: Keywords

    /// Keywords are spliced into a regex alternation that runs on every
    /// keystroke. Only identifier-shaped ones survive — and nothing useful
    /// is lost, because the pattern is `\b(?:…)\b` and a word with no word
    /// characters at its edges could never have matched inside those
    /// boundaries anyway.
    @Test func onlyIdentifierShapedKeywordsSurvive() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "keywords": [
                "def", "end",
                "a|b", ".*", "(", ")", "[a-z]", "a)|(b", "^", "$", "\\",
                "(a+)+$", "->>", "with space", "", "9lives", "_ok", "Mixed1",
                "café"
              ]
            }]
          }
        }
        """#))

        #expect(manifest.languages.first?.keywords == ["def", "end", "_ok", "Mixed1"])
    }

    /// The pattern built from a hostile list still has to compile — a
    /// keyword list that broke the regex would silently turn highlighting
    /// off for the whole language.
    @Test func thePatternBuiltFromHostileKeywordsCompiles() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "keywords": ["def", "a|b", "(a+)+$", ".*"],
              "lineComment": "#"
            }]
          }
        }
        """#))

        let syntax = try #require(manifest.languages.first).syntax
        let pattern = try #require(SyntaxHighlighter.pattern(for: syntax))
        #expect(throws: Never.self) {
            try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
    }

    /// Fifty thousand keywords is not a language; it is a regex somebody
    /// else gets to size. Asserted on the field parser rather than on a
    /// whole manifest because fifty thousand of them do not fit inside the
    /// byte ceiling — which is the other half of the same defence.
    @Test func fiftyThousandKeywordsAreCapped() {
        let many = (0..<50_000).map { "kw\($0)" }
        let parsed = LanguageContribution.keywords(from: many)

        #expect(parsed.count == LanguageContribution.maxKeywords)
        #expect(parsed.first == "kw0")
    }

    @Test func aKeywordListOverTheCapIsTruncatedEndToEnd() throws {
        let many = (0..<(LanguageContribution.maxKeywords + 500))
            .map { "\"kw\($0)\"" }
            .joined(separator: ",")
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{ "languageId": "elixir", "keywords": [\#(many)] }]
          }
        }
        """#))
        #expect(manifest.languages.first?.keywords.count == LanguageContribution.maxKeywords)
    }

    // MARK: Icons

    /// Traversal, absolute paths and tildes all come back nil, and anything
    /// that does resolve is inside the extension's own directory. The
    /// assertion is written as a loop over the whole corpus so that adding a
    /// new escape attempt is one line.
    @Test func everyResolvedIconIsInsideTheExtensionDirectory() {
        let root = URL(fileURLWithPath: "/tmp/phantom-tests/acme.elixir")
        let hostile = [
            "../../etc/passwd",
            "/etc/passwd",
            "~/.ssh/id_rsa",
            "./../sibling/icon.svg",
            "icons/../../../../etc/passwd",
            "..",
            "/",
            "",
            "   ",
        ]

        for candidate in hostile {
            #expect(
                LanguageContribution.iconURL(candidate, root: root) == nil,
                "\(candidate) resolved to something"
            )
        }

        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for candidate in ["icon.svg", "./icons/elixir.svg", "a/b/c.png", "icons/./x.svg"] {
            let resolved = LanguageContribution.iconURL(candidate, root: root)
            #expect(resolved != nil, "\(candidate) resolved to nothing")
            #expect(resolved?.path.hasPrefix(prefix) == true, "\(candidate) escaped the root")
        }
    }

    @Test func anIconWithAnInvisibleScalarIsRefused() {
        #expect(LanguageContribution.iconURL("ic\u{202E}on.svg", root: Self.root) == nil)
        #expect(LanguageContribution.iconURL("icon\n.svg", root: Self.root) == nil)
    }

    // MARK: Commands

    /// Every one of these is a command that needs a shell to mean what it
    /// says, which means its author expected one. The language still loads;
    /// only the process falls away.
    @Test func aCommandThatNeedsAShellIsRefusedAndTheLanguageStillLoads() throws {
        let hostile = [
            "elixir-ls; rm -rf ~",
            "sh -c 'curl x | sh'",
            "$(id)",
            "a && b",
            "a | b",
            "`id`",
            "elixir-ls > /tmp/out",
            "~/bin/elixir-ls",
            "../node_modules/.bin/elixir-ls",
            "./elixir-ls",
            "node_modules/.bin/elixir-ls",
            "/usr/bin/../../tmp/evil",
            "elixir ls",
            "elixir-ls\nrm -rf ~",
            "elixir-ls\u{202E}",
            "el*xir",
            "#elixir-ls",
        ]

        for command in hostile {
            let escapedCommand = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let manifest = try #require(parse(#"""
            {
              "id": "acme.elixir",
              "contributes": {
                "languages": [{
                  "languageId": "elixir",
                  "extensions": ["ex"],
                  "keywords": ["def"],
                  "server": { "command": "\#(escapedCommand)" }
                }]
              }
            }
            """#), "\(command) failed to parse at all")

            let language = try #require(manifest.languages.first)
            #expect(language.server == nil, "\(command) was accepted")
            #expect(language.serverRejection == .unsafeCommand(command), "\(command)")

            #expect(language.fileExtensions == ["ex"], "\(command)")
            #expect(language.keywords == ["def"], "\(command)")
        }
    }

    @Test func aBareNameOrAnAbsolutePathIsLaunchable() {
        #expect(LanguageServerContribution.isLaunchable("elixir-ls"))
        #expect(LanguageServerContribution.isLaunchable("/opt/homebrew/bin/elixir-ls"))
        #expect(!LanguageServerContribution.isLaunchable(""))
        #expect(!LanguageServerContribution.isLaunchable("  "))
        #expect(!LanguageServerContribution.isLaunchable(String(repeating: "a", count: 257)))
    }

    @Test func aServerBlockWithNoCommandSaysSo() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{ "languageId": "elixir", "server": { "args": ["--stdio"] } }]
          }
        }
        """#))
        #expect(manifest.languages.first?.server == nil)
        #expect(manifest.languages.first?.serverRejection == .missingCommand)
    }

    @Test func noServerBlockIsNotARejection() throws {
        let manifest = try #require(parse(#"""
        { "id": "acme.elixir", "contributes": { "languages": [{ "languageId": "elixir" }] } }
        """#))
        #expect(manifest.languages.first?.serverRejection == nil)
    }

    /// A documentation link is dispatched to Launch Services, so a manifest
    /// that could name a `file:` or custom scheme would be a manifest
    /// choosing which application opens.
    @Test func onlyWebDocumentationLinksSurvive() throws {
        let candidates = [
            "https://elixir-lang.org": true,
            "http://elixir-lang.org": true,
            "file:///Applications/Evil.app": false,
            "x-evil://run": false,
            "https:relative": false,
            "javascript:alert(1)": false,
            "not a url": false,
        ]

        for (raw, expected) in candidates {
            let manifest = try #require(parse(#"""
            {
              "id": "acme.elixir",
              "contributes": {
                "languages": [{
                  "languageId": "elixir",
                  "server": { "command": "elixir-ls", "documentationURL": "\#(raw)" }
                }]
              }
            }
            """#))
            /// Interpolated rather than passed straight: `Comment` converts
            /// from a string *literal*, and `raw` is a loop variable.
            #expect(
                (manifest.languages.first?.server?.documentationURL != nil) == expected,
                "\(raw)"
            )
        }
    }

    @Test func initializationOptionsAreKeptAsCanonicalJSON() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "server": {
                "command": "elixir-ls",
                "initializationOptions": { "b": 1, "a": { "deep": true } }
              }
            }]
          }
        }
        """#))
        #expect(
            manifest.languages.first?.server?.initializationOptionsJSON
                == #"{"a":{"deep":true},"b":1}"#
        )
    }

    // MARK: Base language

    /// A contribution is lexed like something. The extension it claims is
    /// the strongest hint, then its comment markers, and `.plain` when
    /// neither says anything — dull, never wrong.
    /// An extension this build already knows wins over the comment markers,
    /// and a single-file component — a container the highlighter splits into
    /// other languages — is never a base a contribution can have.
    @Test func theBaseLanguageComesFromTheStrongestHintAvailable() {
        #expect(
            LanguageContribution.base(fileExtensions: ["ex"], lineComment: "#", blockComment: nil)
                == .python
        )
        #expect(
            LanguageContribution.base(fileExtensions: ["ex"], lineComment: "//", blockComment: nil)
                == .go
        )
        #expect(
            LanguageContribution.base(fileExtensions: ["ex"], lineComment: nil, blockComment: nil)
                == .plain
        )
        #expect(
            LanguageContribution.base(fileExtensions: ["kt"], lineComment: "#", blockComment: nil)
                == .kotlin
        )
        #expect(
            LanguageContribution.base(
                fileExtensions: ["svelte"],
                lineComment: nil,
                blockComment: nil
            ) == .html
        )
    }

    // MARK: Loading from a directory

    @Test func loadingReadsTheManifestOutOfADirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-manifest-" + UUID().uuidString)
            .appendingPathComponent("acme.elixir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        try Data(Self.elixir.utf8)
            .write(to: directory.appendingPathComponent(LanguageManifest.fileName))

        let manifest = try #require(LanguageManifest.load(directory: directory, scope: .user))
        #expect(manifest.id == "acme.elixir")
        #expect(manifest.scope == .user)
        #expect(manifest.digest == LanguageManifest.digest(of: Data(Self.elixir.utf8)))
        #expect(manifest.provenance.manifestPath == directory
            .appendingPathComponent(LanguageManifest.fileName).path)
    }

    @Test func aDirectoryWithNoManifestLoadsNothing() {
        #expect(LanguageManifest.load(directory: Self.root, scope: .user) == nil)
    }
}
