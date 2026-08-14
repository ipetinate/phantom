import Combine
import Foundation

/// The one place that answers "what language is this file, and what starts
/// for it" — the compiled-in registry plus whatever is installed.
///
/// A façade rather than a change to `LSPServerRegistry`, which stays what it
/// has always been: pure data, no filesystem, no app state, answerable in a
/// test with nothing around it. Everything that has to know about disk lives
/// on this side of the seam, and callers that used to reach for the registry
/// reach for this instead.
///
/// Ownership of the precedence rule lives here too, in one method each, so
/// that "the registry wins unless the user promoted this contribution" is
/// stated once rather than re-derived at every call site.
@MainActor
final class LanguageResolver: ObservableObject {
    static let shared = LanguageResolver()

    @Published private(set) var catalog: LanguageCatalog = .empty

    private init() {
        reload()
    }

    /// The directory inside the app bundle holding extensions we ship,
    /// mirroring `FileIconProvider.bundledThemesDir`.
    ///
    /// Nothing ships there yet. The path is read anyway so that shipping one
    /// later is a resource change and not a code change.
    static var bundledExtensionsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("extensions", isDirectory: true)
    }

    func reload() {
        catalog = LanguageCatalog.load(
            bundled: Self.bundledExtensionsDir,
            user: GuiConfigStore.shared.extensionsDirURL,
            promotions: LanguagePromotionStore.all
        )
    }

    // MARK: Resolution

    /// How to lex a file.
    ///
    /// The engine is handed this value; the manifest it came from never
    /// crosses that boundary.
    func syntax(forFileName fileName: String) -> LanguageSyntax {
        if let contributed = catalog.contribution(forFileName: fileName) {
            return contributed.language.syntax
        }
        return .builtIn(CodeLanguage.resolve(fileName: fileName))
    }

    /// The LSP language id for a path, or nil when nothing claims it.
    func languageID(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let contributed = catalog.contribution(forFileName: name) {
            return contributed.language.languageID
        }
        return LSPServerRegistry.languageID(forPath: path)
    }

    /// What to launch for a path.
    ///
    /// A contributed definition carries its own `origin`, which is what the
    /// trust gate reads. A registry definition carries `.builtIn` by
    /// default, so the gate lets it through without a lookup and without a
    /// chance to forget one.
    ///
    /// A contribution that claims the file but ships no server still *owns*
    /// the file, and the answer is nothing rather than the registry's:
    /// falling through would start a server for a language the user has
    /// replaced.
    func serverDefinition(forPath path: String) -> LSPServerDefinition? {
        let name = (path as NSString).lastPathComponent
        if let contributed = catalog.contribution(forFileName: name),
           let definition = contributed.serverDefinition {
            return definition
        }
        if catalog.contribution(forFileName: name) != nil { return nil }
        return LSPServerRegistry.server(forPath: path)
    }

    func serverDefinition(forLanguage languageID: String) -> LSPServerDefinition? {
        if let contributed = catalog.contribution(forLanguageID: languageID),
           let definition = contributed.serverDefinition {
            return definition
        }
        if catalog.contribution(forLanguageID: languageID) != nil { return nil }
        return LSPServerRegistry.server(forLanguage: languageID)
    }

    /// `initializationOptions` a contribution supplied, as JSON text — the
    /// same shape a user's own override is stored in, so it can travel the
    /// same parse.
    func initializationOptionsJSON(forLanguage languageID: String) -> String? {
        catalog.contribution(forLanguageID: languageID)?
            .language.server?.initializationOptionsJSON
    }

    // MARK: User decisions

    /// Moves a contribution ahead of the compiled-in registry, or back.
    ///
    /// The gesture is the user's — a button in Settings. A manifest cannot
    /// ask for this, which is the whole reason the conflict is *shown*
    /// rather than resolved in the file's favour.
    func setPromoted(_ promoted: Bool, extensionID: String, languageID: String) {
        LanguagePromotionStore.setPromoted(
            promoted,
            extensionID: extensionID,
            languageID: languageID
        )
        reload()
    }

    /// Forgets a trust decision, which is how a refusal is undone.
    func forgetTrust(extensionID: String) {
        LanguageTrustStore.forget(extensionID)
    }

    /// The verdict for a contributed language, for a Settings row that wants
    /// to show what would happen without making it happen.
    ///
    /// `resolvedPath` and `workspaceRoot` are the caller's to supply; a row
    /// that only wants to say "not approved yet" can pass the command itself
    /// and no root.
    func trustVerdict(
        for contributed: LanguageCatalog.Contributed,
        resolvedPath: String,
        workspaceRoot: String? = nil
    ) -> LanguageTrust.Verdict? {
        guard let server = contributed.language.server else { return nil }
        let subject = LanguageTrust.Subject(
            origin: .manifest(contributed.provenance),
            digest: contributed.provenance.digest,
            command: server.command,
            resolvedPath: resolvedPath,
            workspaceRoot: workspaceRoot
        )
        return LanguageTrust.verdict(
            for: subject,
            record: LanguageTrustStore.record(for: contributed.provenance.extensionID)
        )
    }
}
