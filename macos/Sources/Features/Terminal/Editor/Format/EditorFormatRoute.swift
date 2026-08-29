import Foundation

/// Whether a Prettier from outside the project gets the last word on ⇧⌘F.
///
/// The ordinary route is settled elsewhere and does not change: the project's
/// own Prettier first — and only when the project declares one, so nothing
/// rewrites a `gofmt` repository's files — then the language server.
///
/// This is about what happens when neither answers. Markdown is the case it
/// exists for. `marksman` offers no formatting at all, so a `.md` file in a
/// repository with no `.prettierrc` — which is most repositories, this one
/// included — answered ⇧⌘F with "This language server doesn't offer
/// formatting": the wrong tool named for a file whose project formats it with
/// `prettier -w .`.
///
/// Only on ⇧⌘F, and that is the whole justification. A save is the editor's
/// own idea and must respect what the project declared; ⇧⌘F is the reader, in
/// this file, now, asking for it by hand.
enum EditorFormatRoute {
    /// - Parameters:
    ///   - trigger: `.save` never takes this route.
    ///   - prettierKnowsTheFile: `PrettierProject.parserCanBeInferred`.
    ///   - server: the status of this file's language server, or nil when no
    ///     server is configured for the language at all.
    ///   - serverFormats: whether it advertised `documentFormattingProvider`.
    static func usesPrettierFromPath(
        trigger: EditorFormatTrigger,
        prettierKnowsTheFile: Bool,
        server: LSPServerStatus?,
        serverFormats: Bool
    ) -> Bool {
        guard trigger == .command, prettierKnowsTheFile, !serverFormats else { return false }

        /// A server still shaking hands has not said what it offers yet, and
        /// `hasCapability` answers false for "not said" exactly as it does for
        /// "does not have it". Taking the fallback here would mean that ⇧⌘F in
        /// the first seconds of a TypeScript file formatted it with Prettier's
        /// defaults instead of with the server that was about to answer.
        if server == .starting { return false }

        /// Every other state is a real answer, failures included. A `.md` file
        /// whose `marksman` is not installed is better served by Prettier than
        /// by a sentence about `marksman`.
        return true
    }

    /// Whether the external formatter for this file gets to run.
    ///
    /// The same deference to the language server, for the same reasons: a
    /// server that formats is the project's own answer, and a server that has
    /// not finished starting has not answered at all.
    ///
    /// What is deliberately missing is the trigger. Prettier from `PATH` is
    /// held to ⇧⌘F because a stray global Prettier would claim files in every
    /// JavaScript-adjacent repository, including ones formatted by something
    /// else. The tools in `ExternalFormatterRegistry` are in the opposite
    /// position — they are the only formatter their language has here, which
    /// is where the language server's own formatter stands, and that one has
    /// always run on a save. Each of them is also a switch in Settings.
    static func usesExternalFormatter(
        server: LSPServerStatus?,
        serverFormats: Bool
    ) -> Bool {
        guard !serverFormats else { return false }
        return server != .starting
    }
}
