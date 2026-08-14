import CryptoKit
import Foundation

/// A language extension's `extension.json`, parsed.
///
/// The envelope is deliberately not "a language file". Phantom is meant to
/// take languages from third parties, and eventually from a store — which
/// means the thing on disk has to carry an identity (`id`), a version, and
/// a publisher long before anything verifies them, because a format that
/// gains identity later cannot be retrofitted onto files already published.
/// `contributes` is the same bet: v1 reads `contributes.languages` and
/// nothing else, and every other key is counted and ignored rather than
/// rejected, so a file written for a later build still installs the half
/// this one understands.
///
/// Parsing is lenient in the shape of `IconTheme`, and for the same reason:
/// these are files we don't control. A missing key, a string where an array
/// belonged, an icon that isn't on disk — each of those costs the manifest
/// that one field, never the load. The single exception is the one place
/// leniency would be dangerous, and it is documented on `eligibility`.
struct LanguageManifest: Equatable, Sendable {
    /// The schema this build reads. Bumped only when the *meaning* of an
    /// existing field changes; adding a field does not need it.
    static let currentSchemaVersion = 1

    /// The manifest's own file name, fixed. `IconTheme` searches for
    /// `*icon-theme.json` because VS Code themes are inconsistent about the
    /// prefix; this format is ours, so there is nothing to guess.
    static let fileName = "extension.json"

    /// A ceiling on the file, checked before it is handed to a JSON parser.
    ///
    /// Every language in this build's own registry would fit in a few
    /// kilobytes. A manifest measured in megabytes is not a language
    /// description; it is a parse this app pays for on every launch.
    static let maxBytes = 512 * 1024

    /// Where a manifest was found, which is the whole of what makes bundled
    /// manifests trusted and user ones not.
    enum Scope: String, Hashable, Sendable, Codable {
        /// Shipped inside the app bundle.
        case bundled

        /// Dropped into the config directory by whoever uses this machine.
        case user
    }

    /// Whether the manifest may contribute the *server* half at all — a
    /// question asked and answered before trust, and independently of it.
    enum ServerEligibility: Equatable, Sendable {
        case eligible

        /// The manifest declares a schema version this build cannot read.
        ///
        /// **This is the one place the parser is deliberately asymmetric,
        /// and it is the security-relevant call in the format.** The
        /// language half of an unknown schema is kept: extensions,
        /// keywords and comment markers are additive and their meaning is
        /// stable, and a keyword cannot hurt anybody. The server half is
        /// discarded, because a later schema is free to change what
        /// `command` *means* — it becomes an array, it gains a flag that
        /// says how to interpret the rest — and reinterpreting a field you
        /// cannot parse under the rules of a version you do not have is
        /// precisely how the wrong program gets launched. Surfaced the way
        /// `IconTheme` surfaces a font-based theme: visible and disabled,
        /// never silently half-working.
        case needsNewerApp(declared: String)

        /// No usable `id`, so no trust decision could be recorded for it.
        ///
        /// A trust record is keyed by identity precisely so that it is not
        /// keyed by a path; a manifest with no identity therefore has
        /// nowhere for an approval to live, and the honest answer is to
        /// contribute the language and refuse the process.
        case unidentified
    }

    let id: String
    let name: String
    let version: String
    let publisher: String
    let eligibility: ServerEligibility
    let languages: [LanguageContribution]

    /// Keys this build ignored, top-level and under `contributes`, so
    /// Settings can say how much of the file it did not understand.
    ///
    /// Names come from a third-party file: escape them before display.
    let unrecognizedFields: [String]

    /// Lowercase hex SHA-256 of the file's **raw bytes**.
    ///
    /// Over the bytes and not over this parsed value, for two reasons that
    /// point the same way: reformatting a manifest is a change to it, and
    /// hashing the parse would let a change in *our* parser silently
    /// re-validate an approval given for different behavior.
    let digest: String

    let manifestURL: URL

    /// The extension's directory. Every relative path in the manifest is
    /// resolved against this and checked to still be inside it.
    let root: URL

    let scope: Scope

    /// The identity a trust record is keyed by.
    var provenance: ExtensionProvenance {
        ExtensionProvenance(
            extensionID: id,
            digest: digest,
            manifestPath: manifestURL.path,
            scope: scope
        )
    }

    /// Identity for lists and for messages that name a shadowing extension:
    /// the `id` when there is one, else the directory — prefixed so it can
    /// never be mistaken for an id a trust record could be keyed by.
    var listIdentity: String {
        id.isEmpty ? "dir:" + root.lastPathComponent : id
    }

    /// Whether this manifest contributes anything at all. An empty file
    /// parses cleanly and lands here, the same way a font-based icon theme
    /// parses cleanly and reports itself unsupported.
    var isUsable: Bool { !languages.isEmpty }

    /// A short reason to show beside an entry that isn't fully in force, or
    /// nil when there is nothing to say.
    var badge: String? {
        switch eligibility {
        case .eligible: return isUsable ? nil : "Contributes nothing"
        case .needsNewerApp: return "Needs a newer Phantom"
        case .unidentified: return "Missing extension id"
        }
    }

    // MARK: Loading

    /// Reads `extension.json` out of one extension directory. Nil only when
    /// there is no manifest there, it is too large, or it is not a JSON
    /// object — every other defect costs a field, not the file.
    ///
    /// The size is checked on the bytes rather than after parsing, because
    /// the point is to not hand an arbitrary-sized file to a parser at all.
    static func load(directory: URL, scope: Scope) -> LanguageManifest? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }

        guard data.count <= maxBytes else { return nil }

        return parse(data: data, url: url, root: directory, scope: scope)
    }

    static func parse(data: Data, url: URL, root: URL, scope: Scope) -> LanguageManifest? {
        guard data.count <= maxBytes else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        return parse(json: json, digest: digest(of: data), url: url, root: root, scope: scope)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Parsing

    /// The keys v1 knows about, at the top level and inside `contributes`.
    /// Anything else is counted so the UI can be honest about how much of
    /// the file this build ignored.
    private static let knownTopLevelKeys: Set<String> = [
        "schemaVersion", "id", "name", "version", "publisher", "contributes",
    ]
    private static let knownContributesKeys: Set<String> = ["languages"]

    /// Builds the value from an already-decoded object and a digest taken
    /// over the bytes it was decoded from.
    ///
    /// The directory name is used as a display fallback for `name` and never
    /// as the identity: `id` stays empty when the file has no usable one,
    /// and an empty identity is what turns the server half off.
    static func parse(
        json: [String: Any],
        digest: String,
        url: URL,
        root: URL,
        scope: Scope
    ) -> LanguageManifest {
        let contributes = json["contributes"] as? [String: Any] ?? [:]

        var unrecognized = json.keys.filter { !knownTopLevelKeys.contains($0) }
        unrecognized += contributes.keys
            .filter { !knownContributesKeys.contains($0) }
            .map { "contributes." + $0 }

        let id = validID(json["id"]) ?? ""
        let eligibility = self.eligibility(
            declaredSchemaVersion: json["schemaVersion"],
            id: id
        )

        let rawLanguages = contributes["languages"] as? [Any] ?? []
        let languages = rawLanguages
            .prefix(maxLanguages)
            .compactMap { $0 as? [String: Any] }
            .compactMap {
                LanguageContribution.parse(json: $0, root: root, eligibility: eligibility)
            }

        return LanguageManifest(
            id: id,
            name: string(json["name"]) ?? root.lastPathComponent,
            version: string(json["version"]) ?? "",
            publisher: string(json["publisher"]) ?? "",
            eligibility: eligibility,
            languages: dedupedByLanguageID(languages),
            unrecognizedFields: unrecognized.sorted(),
            digest: digest,
            manifestURL: url,
            root: root,
            scope: scope
        )
    }

    /// One extension contributing the same `languageId` twice is a mistake
    /// in the file, and the deterministic reading is that the first entry
    /// wins — the same rule `LSPServerRegistry` applies to its own table.
    private static func dedupedByLanguageID(
        _ languages: [LanguageContribution]
    ) -> [LanguageContribution] {
        var seen: Set<String> = []
        return languages.filter { seen.insert($0.languageID).inserted }
    }

    /// More than this in one extension is not a language pack, and each one
    /// costs a compiled regex.
    static let maxLanguages = 64

    /// Whether the manifest may contribute a server.
    ///
    /// An absent `schemaVersion` is read as v1. There is no earlier schema
    /// for it to mean, and omitting the key buys an author nothing: v1 is
    /// the strictest set of rules this build has. A key that is *present*
    /// and unreadable is a different thing entirely — a file written against
    /// rules we do not have.
    private static func eligibility(
        declaredSchemaVersion: Any?,
        id: String
    ) -> ServerEligibility {
        if let declared = declaredSchemaVersion {
            guard let integer = integerSchemaVersion(declared) else {
                return .needsNewerApp(declared: String(describing: declared))
            }
            guard integer <= currentSchemaVersion else {
                return .needsNewerApp(declared: String(integer))
            }
        }

        guard !id.isEmpty else { return .unidentified }
        return .eligible
    }

    /// A declared schema version, or nil when the value is not a number this
    /// build can compare against its own.
    ///
    /// `as? Int` is not enough, and the reason is a measured trap: JSON
    /// `true` arrives as an `NSNumber` that bridges to `Int` as 1, and `1`
    /// bridges to `Bool` as `true`, so neither cast alone can tell the two
    /// apart. Only the CoreFoundation type id can. `1.0` is accepted,
    /// because its value is integral and there is nothing ambiguous about
    /// it; `1.5` is not, because there is no version it could mean.
    private static func integerSchemaVersion(_ declared: Any) -> Int? {
        guard let number = declared as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    // MARK: Field validation

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An extension id, or nil.
    ///
    /// Kept to a charset that is safe as a `UserDefaults` dictionary key and
    /// as a display string: dots are allowed because `publisher.language` is
    /// the convention a store will want, but `..` and any separator are not,
    /// so an id can never be read as a path.
    static func validID(_ value: Any?) -> String? {
        guard let raw = string(value), raw.count <= 128 else { return nil }
        guard !raw.contains(".."), !raw.hasPrefix("."), !raw.hasSuffix(".") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard raw.allSatisfy(allowed.contains) else { return nil }
        return raw
    }
}

/// One entry of `contributes.languages`.
struct LanguageContribution: Equatable, Sendable {
    /// Why this contribution has no server, when it asked for one. Nil
    /// either because it never asked or because it got one.
    enum ServerRejection: Equatable, Sendable {
        /// The command is not a program name — it needs a shell to mean
        /// what it says, which means its author expected a shell.
        case unsafeCommand(String)

        /// A `server` block with nothing to run.
        case missingCommand

        /// The manifest's schema, or its identity, disqualified it. See
        /// `LanguageManifest.ServerEligibility`.
        case ineligible(LanguageManifest.ServerEligibility)
    }

    /// The LSP `languageId`. Also a `UserDefaults` key (per-language
    /// completion settings are stored by it) and a cache key in the
    /// highlighter, which is why the charset is narrow and why `/` and `..`
    /// are not in it.
    let languageID: String

    let displayName: String

    /// Lower-cased, without the leading dot.
    let fileExtensions: [String]

    /// Lower-cased whole file names, for the languages whose extension does
    /// not decide anything — `mix.lock`, `go.mod`.
    let fileNames: [String]

    /// Identifier-shaped words only. See `LanguageContribution.keywords(from:)`.
    let keywords: [String]

    let lineComment: String?
    let blockComment: LanguageSyntax.BlockComment?
    let category: LSPServerCategory

    /// The compiled-in language this one is lexed like.
    let base: CodeLanguage

    /// Artwork for the settings row, already proven to be inside the
    /// extension's own directory, or nil.
    let iconURL: URL?

    let server: LanguageServerContribution?
    let serverRejection: ServerRejection?

    /// The value the engine gets. The manifest itself never crosses that
    /// boundary; this does.
    var syntax: LanguageSyntax {
        .contributed(
            id: languageID,
            base: base,
            keywords: keywords,
            lineComment: lineComment,
            blockComment: blockComment
        )
    }

    /// Every claim this contribution makes on a file, as opaque tokens. The
    /// catalog resolves conflicts on these and nothing else, so extensions,
    /// file names and the language id itself are compared the same way.
    var claims: [String] {
        ["lang:" + languageID]
            + fileExtensions.map { "ext:" + $0 }
            + fileNames.map { "name:" + $0 }
    }

    // MARK: Parsing

    static func parse(
        json: [String: Any],
        root: URL,
        eligibility: LanguageManifest.ServerEligibility
    ) -> LanguageContribution? {
        guard let languageID = validLanguageID(json["languageId"]) else { return nil }

        let fileExtensions = self.fileExtensions(from: json["extensions"])
        let fileNames = self.fileNames(from: json["fileNames"])
        let lineComment = commentMarker(json["lineComment"])
        let blockComment = self.blockComment(json["blockComment"])

        let rawServer = json["server"] as? [String: Any]
        let server: LanguageServerContribution?
        let rejection: ServerRejection?
        switch eligibility {
        case .eligible:
            (server, rejection) = LanguageServerContribution.parse(json: rawServer)
        case .needsNewerApp, .unidentified:
            server = nil
            rejection = rawServer == nil ? nil : .ineligible(eligibility)
        }

        return LanguageContribution(
            languageID: languageID,
            displayName: LanguageManifest.string(json["name"]) ?? languageID,
            fileExtensions: fileExtensions,
            fileNames: fileNames,
            keywords: keywords(from: json["keywords"]),
            lineComment: lineComment,
            blockComment: blockComment,
            category: LSPServerCategory(rawValue: LanguageManifest.string(json["category"]) ?? "")
                ?? .script,
            base: base(
                fileExtensions: fileExtensions,
                lineComment: lineComment,
                blockComment: blockComment
            ),
            iconURL: iconURL(json["icon"], root: root),
            server: server,
            serverRejection: rejection
        )
    }

    static func validLanguageID(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value)?.lowercased(), raw.count <= 64
        else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_+-")
        guard raw.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    /// A cap on each list. Generous next to any real language and small
    /// enough that the tables the catalog builds from them stay bounded.
    static let maxFileTypes = 128

    /// Extensions, lower-cased and without their leading dot.
    ///
    /// Cast as `[Any]` and not `[String]`, so one non-string element costs
    /// that element rather than the list.
    ///
    /// Dots inside an extension are refused. The resolver matches the
    /// last-dot extension exactly as `LSPServerRegistry` does, so a
    /// multi-part extension could never match anything — and allowing dots
    /// would also allow `..`, which has no business in a lookup key.
    static func fileExtensions(from value: Any?) -> [String] {
        let raw = (value as? [Any])?.compactMap { $0 as? String } ?? []
        var seen: Set<String> = []
        return raw.compactMap { candidate -> String? in
            var text = candidate.trimmingCharacters(in: .whitespaces).lowercased()
            if text.hasPrefix(".") { text.removeFirst() }
            guard !text.isEmpty, text.count <= 32 else { return nil }
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_+-")
            guard text.allSatisfy(allowed.contains) else { return nil }
            return seen.insert(text).inserted ? text : nil
        }
        .prefix(maxFileTypes)
        .map { $0 }
    }

    static func fileNames(from value: Any?) -> [String] {
        let raw = (value as? [Any])?.compactMap { $0 as? String } ?? []
        var seen: Set<String> = []
        return raw.compactMap { candidate -> String? in
            let text = candidate.trimmingCharacters(in: .whitespaces).lowercased()
            guard !text.isEmpty, text.count <= 128 else { return nil }
            guard text != ".", text != ".." else { return nil }
            guard !text.contains("/"), !text.contains("\\") else { return nil }
            guard !text.unicodeScalars.contains(where: isUnsafeScalar) else { return nil }
            return seen.insert(text).inserted ? text : nil
        }
        .prefix(maxFileTypes)
        .map { $0 }
    }

    /// The most keywords a language gets to add.
    ///
    /// They are joined into one regex alternation that the highlighter runs
    /// over the viewport on every keystroke, so the list is a cost paid per
    /// character typed. The largest list this build ships is under eighty.
    static let maxKeywords = 1024

    /// Keywords, keeping only the ones that are identifier-shaped.
    ///
    /// The first of two independent defences against a keyword that is
    /// really a regex — the second is `SyntaxRules.words(escaping:)`. What
    /// makes this filter cheap to accept is that it discards nothing
    /// useful: the pattern is `\b(?:…)\b`, and a "keyword" with no word
    /// characters at its edges could never match inside those boundaries
    /// anyway. So `->>` is dropped because it would never have painted
    /// anything, not only because `|` and `(` are dangerous.
    static func keywords(from value: Any?) -> [String] {
        let raw = (value as? [Any])?.compactMap { $0 as? String } ?? []
        var seen: Set<String> = []
        return raw.compactMap { candidate -> String? in
            guard isIdentifierShaped(candidate) else { return nil }
            return seen.insert(candidate).inserted ? candidate : nil
        }
        .prefix(maxKeywords)
        .map { $0 }
    }

    static func isIdentifierShaped(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 64 else { return false }
        var scalars = candidate.unicodeScalars.makeIterator()
        guard let first = scalars.next(), isWordScalar(first), !("0"..."9").contains(first)
        else { return false }
        while let next = scalars.next() {
            guard isWordScalar(next) else { return false }
        }
        return true
    }

    /// ASCII word characters only. A regex `\b` is defined against the
    /// engine's own word set, and keeping to the part of it that is the same
    /// everywhere is what makes the pattern behave the way it reads.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar)
            || ("A"..."Z").contains(scalar)
            || ("0"..."9").contains(scalar)
            || scalar == "_"
    }

    /// A comment marker: short, printable, one line.
    static func commentMarker(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= 8 else { return nil }
        guard !raw.unicodeScalars.contains(where: isUnsafeScalar) else { return nil }
        return raw
    }

    static func blockComment(_ value: Any?) -> LanguageSyntax.BlockComment? {
        guard let pair = value as? [Any], pair.count == 2,
              let open = commentMarker(pair[0]),
              let close = commentMarker(pair[1])
        else { return nil }
        return LanguageSyntax.BlockComment(open: open, close: close)
    }

    /// An icon path, resolved against the extension's own directory and
    /// proven to still be inside it.
    ///
    /// Built by appending rather than with `URL(fileURLWithPath:relativeTo:)`,
    /// for the reason `IconTheme.iconURL` gives: that initializer resolves
    /// against the *parent* when the base carries no trailing slash. The
    /// containment check is what makes `../../etc/passwd` and `/etc/passwd`
    /// come back as nil instead of as a file this app then reads and draws.
    ///
    /// It is made twice against the same resolved base so that both the dot
    /// traversal in the path and a symlink inside the extension pointing out
    /// of it have to fail it.
    static func iconURL(_ value: Any?, root: URL) -> URL? {
        guard let raw = LanguageManifest.string(value) else { return nil }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        guard !raw.unicodeScalars.contains(where: isUnsafeScalar) else { return nil }

        let trimmed = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(trimmed).standardizedFileURL

        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(prefix),
              candidate.resolvingSymlinksInPath().path.hasPrefix(prefix)
        else { return nil }
        return candidate
    }

    /// Scalars that must not reach a display string or a lookup key.
    ///
    /// The same set `UntrustedURL` rejects, and for the same reason: a
    /// bidirectional override or a newline lets a file decide what the UI
    /// appears to say about it.
    static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        UntrustedURL.isUnsafeDisplayScalar(scalar)
    }

    // MARK: Base language

    /// The compiled-in language a contribution is lexed like.
    ///
    /// Tried in the order the signals are trustworthy. First, whatever this
    /// build already resolves one of the claimed extensions to — right for
    /// the common case of a contribution that adds a *server* for a
    /// language the highlighter can already read. Then the comment markers,
    /// which are the only other honest statement a manifest makes about how
    /// the language is written; they decide the shape of strings and
    /// numbers, which is all a base is really for once the keywords and the
    /// comment pattern have been replaced. Failing both, `.plain`: keywords
    /// and comments, nothing else. Dull, never wrong.
    ///
    /// Never `.vue`: a single-file component is a container the highlighter
    /// splits into three other languages, and a contribution cannot be one.
    static func base(
        fileExtensions: [String],
        lineComment: String?,
        blockComment: LanguageSyntax.BlockComment?
    ) -> CodeLanguage {
        for candidate in fileExtensions {
            let resolved = CodeLanguage.resolve(fileName: "f." + candidate)
            guard resolved != .plain else { continue }
            return resolved == .vue ? .html : resolved
        }

        switch (lineComment, blockComment?.open) {
        case ("//", _): return .go
        case ("#", _): return .python
        case ("--", _): return .sql
        case (_, "<!--"): return .html
        case (_, "/*"): return .go
        default: return .plain
        }
    }
}

/// The `server` half of a language contribution: how to start it, and what
/// to tell the user when it isn't installed.
struct LanguageServerContribution: Equatable, Sendable {
    /// Resolved on the login shell's `PATH` and launched directly, never
    /// through a shell — the same contract `LSPServerDefinition.command`
    /// has.
    let command: String

    let arguments: [String]

    /// **Display and copy only.** This string never reaches the Install
    /// button in Settings, and that restriction is not stylistic: the
    /// Install button is the one place in this app where a string becomes
    /// `$SHELL -lic`, and a manifest-supplied string arriving there would
    /// turn "run this named binary, once you approve it" into "run this
    /// sentence". The button is not offered for contributed languages at
    /// all; this is the text beside it.
    let installHint: String

    /// Only `http`/`https` with a host, decided by `UntrustedURL` rather
    /// than by a fresh guess — a documentation link is dispatched to Launch
    /// Services, so a `file:` or custom scheme here would be a manifest
    /// choosing which application opens.
    let documentationURL: URL?

    /// `initializationOptions` re-encoded as JSON text.
    ///
    /// Kept as text so it travels the path a user's own override already
    /// travels — the same parse, the same failure message — rather than a
    /// second decoder that could disagree with it.
    let initializationOptionsJSON: String?

    /// There is deliberately **no `env`**.
    ///
    /// A manifest that could set environment variables could set
    /// `DYLD_INSERT_LIBRARIES`, and that turns the approval the user gave —
    /// "run this named binary" — into "run any code, inside that binary".
    /// The approval prompt would still name `elixir-ls`, truthfully, and be
    /// meaningless.
    static let maxArguments = 32

    static func parse(
        json: [String: Any]?
    ) -> (LanguageServerContribution?, LanguageContribution.ServerRejection?) {
        guard let json else { return (nil, nil) }

        guard let rawCommand = LanguageManifest.string(json["command"]) else {
            return (nil, .missingCommand)
        }
        guard isLaunchable(rawCommand) else {
            return (nil, .unsafeCommand(rawCommand))
        }

        let arguments = (json["args"] as? [Any])?
            .compactMap { $0 as? String }
            .filter { !$0.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar) }
            .prefix(maxArguments)
            .map { $0 } ?? []

        let contribution = LanguageServerContribution(
            command: rawCommand,
            arguments: arguments,
            installHint: installHint(json["installHint"]),
            documentationURL: documentationURL(json["documentationURL"]),
            initializationOptionsJSON: initializationOptionsJSON(json["initializationOptions"])
        )
        return (contribution, nil)
    }

    /// Whether a manifest-supplied command may be launched at all.
    ///
    /// Not "is it installed" — that is `LSPProcess.locate`'s question. This
    /// asks whether the string is a *program*, and refuses anything that
    /// only means something to a shell. Nothing in this app passes a command
    /// to a shell today; the check exists because the cost of being wrong
    /// about that later is arbitrary code execution, and because a command
    /// that needs a shell is a command whose author was expecting one.
    ///
    /// A relative path is refused for a sharper reason: the server is
    /// launched with the workspace as its working directory, so
    /// `../../bin/tool` is the freshly-cloned-repo attack wearing a
    /// different hat. A path has to be absolute to be a path here.
    static func isLaunchable(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= 256 else { return false }
        guard !command.unicodeScalars.contains(where: isForbiddenCommandScalar) else {
            return false
        }
        if command.contains("/") {
            guard command.hasPrefix("/") else { return false }
            guard !command.contains("/../"), !command.hasSuffix("/..") else { return false }
        }
        return true
    }

    /// Shell metacharacters, whitespace, and `~`.
    ///
    /// Whitespace is in the list because arguments have their own field: a
    /// command with a space in it is either `sh -c …` or a path this app
    /// would fail to resolve anyway, and both answers are "no". `~` is in it
    /// because `LSPProcess.locate` expands tildes, so it is a path
    /// component with a meaning that depends on who is running.
    private static func isForbiddenCommandScalar(_ scalar: Unicode.Scalar) -> Bool {
        if LanguageContribution.isUnsafeScalar(scalar) { return true }
        if scalar.properties.isWhitespace { return true }
        return "~;&|<>$`()[]{}*?!#'\"\\\n\r\t".unicodeScalars.contains(scalar)
    }

    static func installHint(_ value: Any?) -> String {
        guard let raw = LanguageManifest.string(value) else { return "" }
        return String(raw.prefix(512))
    }

    static func documentationURL(_ value: Any?) -> URL? {
        guard let raw = LanguageManifest.string(value) else { return nil }
        guard case .allow(let url) = UntrustedURL(raw).decision,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    static func initializationOptionsJSON(_ value: Any?) -> String? {
        guard let object = value as? [String: Any], !object.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
