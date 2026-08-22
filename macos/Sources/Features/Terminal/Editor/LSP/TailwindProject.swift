import Foundation

/// Whether a file belongs to a project that has Tailwind installed, and
/// therefore whether the Tailwind language server has anything to say about it.
///
/// The same shape as `TypeScriptToolchain` and for the same reason: which
/// servers serve a file is a fact about its project, `LSPServerRegistry` is
/// pure and may not touch a disk, so the fact is resolved here and handed in
/// as a value.
///
/// **Why gate it at all.** The server is not harmless when Tailwind is absent:
/// it starts, finds no project, and then answers every completion inside every
/// `class` attribute with nothing — while the class-attribute exception in
/// `CodeCompletionTrigger` has already turned off the string suppression that
/// keeps prose quiet. Routing it only where Tailwind exists is what keeps that
/// exception paid for.
enum TailwindProject: Equatable, Sendable {
    /// Tailwind is installed at this absolute directory — the package's own,
    /// so the message that mentions it can be specific.
    case installed(at: String)

    /// No Tailwind anywhere between the file and the workspace root.
    case absent

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// Where a project keeps Tailwind, relative to whichever directory holds
    /// the `node_modules` that has it.
    ///
    /// One path covers both major versions: v4 renamed the CLI and moved the
    /// configuration into CSS, but the package a project installs is still
    /// `tailwindcss`.
    static let localPath = "node_modules/tailwindcss"

    /// What this file's project has.
    ///
    /// **Walks up**, unlike `TypeScriptToolchain.resolve`, and the asymmetry is
    /// deliberate. That one has a useful answer when it finds nothing —
    /// `.native`, which still starts a server — so looking only in the
    /// project's own directory costs nothing. This one's empty answer is *the
    /// feature is absent*, and a monorepo hoists `node_modules` to the repo
    /// root, so stopping at the file's own package would silently disable
    /// Tailwind completion in exactly the repositories most likely to have it.
    ///
    /// Still cheap enough for the routing path — `LSPCenter.keys(forPath:)`
    /// runs this per debounced change — because each level is one `stat` and
    /// the walk is bounded by the workspace root. A file five directories deep
    /// costs six.
    static func resolve(
        forPath path: String,
        root: String,
        fileManager: FileManager = .default
    ) -> TailwindProject {
        var directory = (path as NSString).deletingLastPathComponent
        let root = (root as NSString).standardizingPath

        while true {
            let candidate = (directory as NSString).appendingPathComponent(localPath)
            if fileManager.fileExists(atPath: candidate) {
                return .installed(at: candidate)
            }

            /// The root is checked and then the walk stops, rather than the
            /// walk stopping when it reaches the root: a file *at* the root
            /// has to be looked at once.
            guard directory != root, directory != "/", !directory.isEmpty else { return .absent }

            let parent = (directory as NSString).deletingLastPathComponent
            guard parent != directory else { return .absent }
            directory = parent
        }
    }
}
