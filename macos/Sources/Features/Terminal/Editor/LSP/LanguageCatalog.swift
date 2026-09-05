import Foundation

/// Every language extension found on disk, and which of their contributions
/// are actually in force.
///
/// Scanned the way `FileIconProvider.reload()` scans icon themes: bundled
/// directory first, then the user's, one entry per subdirectory that holds
/// the manifest, and an entry that cannot be honored is listed as disabled
/// rather than dropped. A silently missing extension is a support question;
/// a listed one with a reason beside it answers itself.
///
/// The resolution order is the part worth reading:
///
/// 1. a promoted contribution from the user's directory
/// 2. a promoted contribution from the bundle
/// 3. **the compiled-in registry**
/// 4. a contribution from the user's directory
/// 5. a contribution from the bundle
///
/// The registry sitting third is the invariant the whole design turns on:
/// copying a file into a directory must never change a language the user
/// already had. Promotion moves a contribution above it, and promotion is a
/// click in Settings — never something the file can ask for.
///
/// Ties inside a rank are broken by **directory name, lexicographically**,
/// and the loser stays in the catalog marked conflicted. Which one wins
/// matters far less than that the answer is the same on every machine:
/// resolution that depended on `contentsOfDirectory` order would be a bug
/// that reproduces for one person and not the next.
struct LanguageCatalog: Equatable {
    /// One extension directory that held a readable manifest.
    struct Entry: Equatable, Identifiable {
        let manifest: LanguageManifest

        /// A manifest with no id contributes no server, but it still has to
        /// be nameable in a list.
        var id: String { manifest.listIdentity }
    }

    /// One contributed language, and where it landed.
    struct Contributed: Equatable, Identifiable {
        let provenance: ExtensionProvenance

        /// What to call the owning extension in a list. Not the trust key —
        /// see `LanguageManifest.listIdentity`.
        let listIdentity: String

        let extensionName: String
        let extensionVersion: String
        let publisher: String
        let language: LanguageContribution
        let resolution: Resolution

        /// Where the manifest lives, for a Reveal in Finder that does not
        /// have to reconstruct it.
        let manifestURL: URL

        var id: String { listIdentity + "#" + language.languageID }

        var isActive: Bool { resolution == .active }

        /// The server definition to launch, carrying its own provenance so
        /// the trust gate cannot be reached without it.
        ///
        /// Nil when the contribution has no server, is not in force, or the
        /// manifest was not eligible to contribute one at all.
        var serverDefinition: LSPServerDefinition? {
            guard isActive, let server = language.server else { return nil }
            return LSPServerDefinition(
                languageID: language.languageID,
                displayName: language.displayName,
                command: server.command,
                arguments: server.arguments,
                installHint: server.installHint,
                origin: .manifest(provenance)
            )
        }
    }

    struct ContributedFormatter: Equatable, Identifiable {
        let provenance: ExtensionProvenance
        let listIdentity: String
        let extensionName: String
        let extensionVersion: String
        let publisher: String
        let formatter: FormatterContribution
        let resolution: Resolution
        let manifestURL: URL

        var id: String { listIdentity + "#formatter:" + formatter.id }

        var isActive: Bool { resolution == .active }

        var externalFormatter: ExternalFormatter? {
            guard isActive else { return nil }
            return ExternalFormatter(
                id: id,
                languageName: extensionName,
                displayName: formatter.name,
                command: formatter.command,
                arguments: formatter.arguments,
                extensions: Set(formatter.fileExtensions),
                installHint: formatter.installHint,
                note: nil,
                provenance: provenance
            )
        }
    }

    enum Resolution: Equatable, Sendable {
        case active

        /// Parsed and listed, but not in effect: something ahead of it in
        /// the order already claims a file type it wanted.
        case shadowed(by: Shadow, claim: String)
    }

    enum Shadow: Equatable, Sendable {
        /// The compiled-in registry, or the highlighter's own language
        /// table — either is "a language the user already had".
        case builtIn

        /// Another extension, named so Settings can say which.
        case extensionID(String)
    }

    let entries: [Entry]
    let contributed: [Contributed]
    let formatters: [ContributedFormatter]

    static let empty = LanguageCatalog(entries: [], contributed: [], formatters: [])

    // MARK: Lookup

    /// The contribution in force for a file, or nil when this build's own
    /// tables own it.
    ///
    /// Matched the way `LSPServerRegistry.languageID(forPath:)` matches:
    /// **a whole file name beats an extension**, because a name is the more
    /// specific statement — `go.mod` is Go, and `.mod` is a Fortran module
    /// as often as it is anything else.
    func contribution(forFileName fileName: String) -> Contributed? {
        let lowered = fileName.lowercased()
        if let byName = contributed.first(where: {
            $0.isActive && $0.language.fileNames.contains(lowered)
        }) {
            return byName
        }

        let ext = (lowered as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return contributed.first {
            $0.isActive && $0.language.fileExtensions.contains(ext)
        }
    }

    func contribution(forLanguageID languageID: String) -> Contributed? {
        let lowered = languageID.lowercased()
        return contributed.first { $0.isActive && $0.language.languageID == lowered }
    }

    func formatter(forFileName fileName: String) -> ContributedFormatter? {
        let ext = (fileName.lowercased() as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return formatters.first { $0.isActive && $0.formatter.fileExtensions.contains(ext) }
    }

    // MARK: Loading

    /// Reads both directories and resolves the result.
    ///
    /// Promotions are passed in rather than read here so the resolution is
    /// testable without touching the defaults a running Phantom reads.
    static func load(
        bundled: URL?,
        user: URL?,
        promotions: Set<String>
    ) -> LanguageCatalog {
        var manifests: [LanguageManifest] = []
        for (directory, scope) in [(bundled, LanguageManifest.Scope.bundled), (user, .user)] {
            guard let directory else { continue }
            manifests += load(directory: directory, scope: scope)
        }
        return resolve(manifests: manifests, promotions: promotions)
    }

    static func load(directory: URL, scope: LanguageManifest.Scope) -> [LanguageManifest] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return LanguageManifest.load(directory: entry, scope: scope)
        }
    }

    // MARK: Resolution

    /// Precedence, lowest number first. The registry's own rank is between
    /// promoted and unpromoted contributions, which is the entire policy in
    /// one integer.
    private static let registryRank = 2

    private static func rank(scope: LanguageManifest.Scope, promoted: Bool) -> Int {
        switch (scope, promoted) {
        case (.user, true): return 0
        case (.bundled, true): return 1
        case (.user, false): return 3
        case (.bundled, false): return 4
        }
    }

    /// One contribution with everything the ordering needs, worked out once.
    private struct Candidate {
        let manifest: LanguageManifest
        let language: LanguageContribution
        let rank: Int
        let directory: String
    }

    /// Works out which contributions are in force.
    ///
    /// Everything is sorted before anything is claimed, so the outcome is a
    /// function of the files rather than of the order the filesystem listed
    /// them in. Ties fall back to the directory name compared **scalar by
    /// scalar** rather than with `localizedStandardCompare`, because the
    /// answer has to be the same in every locale.
    ///
    /// A contribution is shadowed whole rather than claim by claim. One that
    /// claims `ex` and `exs` where only `ex` is taken would otherwise be half
    /// a language — highlighting one file and not the one beside it — and no
    /// user could be expected to work that out.
    static func resolve(
        manifests: [LanguageManifest],
        promotions: Set<String>
    ) -> LanguageCatalog {
        let ordered = manifests
            .flatMap { manifest in
                manifest.languages.map { language in
                    Candidate(
                        manifest: manifest,
                        language: language,
                        rank: rank(
                            scope: manifest.scope,
                            promoted: promotions.contains(LanguagePromotionStore.key(
                                extensionID: manifest.id,
                                languageID: language.languageID
                            ))
                        ),
                        directory: manifest.root.lastPathComponent
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.directory != rhs.directory { return lhs.directory < rhs.directory }
                return lhs.language.languageID < rhs.language.languageID
            }

        var claimed: [String: String] = [:]
        var contributed: [Contributed] = []

        for pair in ordered {
            let outranksRegistry = pair.rank < registryRank

            var resolution = Resolution.active
            for claim in pair.language.claims {
                if let owner = claimed[claim] {
                    resolution = .shadowed(by: .extensionID(owner), claim: claim)
                    break
                }
                if !outranksRegistry, builtInOwns(claim) {
                    resolution = .shadowed(by: .builtIn, claim: claim)
                    break
                }
            }

            if resolution == .active {
                for claim in pair.language.claims {
                    claimed[claim] = pair.manifest.listIdentity
                }
            }

            contributed.append(Contributed(
                provenance: pair.manifest.provenance,
                listIdentity: pair.manifest.listIdentity,
                extensionName: pair.manifest.name,
                extensionVersion: pair.manifest.version,
                publisher: pair.manifest.publisher,
                language: pair.language,
                resolution: resolution,
                manifestURL: pair.manifest.manifestURL
            ))
        }

        let entries = manifests
            .map(Entry.init(manifest:))
            .sorted { $0.id < $1.id }

        return LanguageCatalog(
            entries: entries,
            contributed: contributed,
            formatters: resolveFormatters(manifests: manifests)
        )
    }

    static func resolveFormatters(manifests: [LanguageManifest]) -> [ContributedFormatter] {
        let ordered = manifests
            .flatMap { manifest in manifest.formatters.map { (manifest: manifest, formatter: $0) } }
            .sorted { lhs, rhs in
                let lhsRank = rank(scope: lhs.manifest.scope, promoted: false)
                let rhsRank = rank(scope: rhs.manifest.scope, promoted: false)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsDirectory = lhs.manifest.root.lastPathComponent
                let rhsDirectory = rhs.manifest.root.lastPathComponent
                if lhsDirectory != rhsDirectory { return lhsDirectory < rhsDirectory }
                return lhs.formatter.id < rhs.formatter.id
            }

        var claimed: [String: String] = [:]
        return ordered.map { manifest, formatter in
            var resolution = Resolution.active
            for ext in formatter.fileExtensions {
                if let owner = claimed[ext] {
                    resolution = .shadowed(by: .extensionID(owner), claim: "ext:" + ext)
                    break
                }
                if ExternalFormatterRegistry.formatter(forFileNamed: "f." + ext) != nil {
                    resolution = .shadowed(by: .builtIn, claim: "ext:" + ext)
                    break
                }
            }
            if resolution == .active {
                for ext in formatter.fileExtensions { claimed[ext] = manifest.listIdentity }
            }
            return ContributedFormatter(
                provenance: manifest.provenance,
                listIdentity: manifest.listIdentity,
                extensionName: manifest.name,
                extensionVersion: manifest.version,
                publisher: manifest.publisher,
                formatter: formatter,
                resolution: resolution,
                manifestURL: manifest.manifestURL
            )
        }
    }

    /// Whether this build already owns a claim.
    ///
    /// Both compiled-in tables count, because both are "a language the user
    /// already had": `LSPServerRegistry` decides which server starts, and
    /// `CodeLanguage` decides how the file is coloured. An extension that
    /// took `.svelte` from the highlighter without taking a server from
    /// anybody would still have changed something the user did not ask to
    /// change.
    static func builtInOwns(_ claim: String) -> Bool {
        if let languageID = claim.dropPrefixIfPresent("lang:") {
            return LSPServerRegistry.server(forLanguage: languageID) != nil
        }
        if let ext = claim.dropPrefixIfPresent("ext:") {
            let sample = "f." + ext
            return LSPServerRegistry.languageID(forPath: sample) != nil
                || CodeLanguage.resolve(fileName: sample) != .plain
        }
        if let name = claim.dropPrefixIfPresent("name:") {
            return LSPServerRegistry.languageID(forPath: name) != nil
                || CodeLanguage.namedFiles.contains(name)
        }
        return false
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
