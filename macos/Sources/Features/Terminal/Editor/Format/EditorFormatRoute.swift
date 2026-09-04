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
    ///   - handshakeTimedOut: whether the caller already waited out
    ///     `serverSettleTimeout` and the server is *still* starting.
    static func usesPrettierFromPath(
        trigger: EditorFormatTrigger,
        prettierKnowsTheFile: Bool,
        server: LSPServerStatus?,
        serverFormats: Bool,
        handshakeTimedOut: Bool
    ) -> Bool {
        guard trigger == .command, prettierKnowsTheFile, !serverFormats else { return false }

        /// A server still shaking hands has not said what it offers yet, and
        /// `hasCapability` answers false for "not said" exactly as it does for
        /// "does not have it". Taking the fallback here would mean that ⇧⌘F in
        /// the first seconds of a TypeScript file formatted it with Prettier's
        /// defaults instead of with the server that was about to answer.
        ///
        /// Which is why the caller waits — see `waitsForServer` — and why the
        /// wait having expired is a separate fact from the server's state. A
        /// handshake that has not finished after `serverSettleTimeout` is not
        /// an answer the reader should keep being told about: the first ⇧⌘F on
        /// a Markdown file, typed while `marksman` was still loading the
        /// folder, reported "this language server doesn't offer formatting"
        /// about a server that had not yet said anything at all.
        if server == .starting, !handshakeTimedOut { return false }

        /// Every other state is a real answer, failures included. A `.md` file
        /// whose `marksman` is not installed is better served by Prettier than
        /// by a sentence about `marksman`.
        return true
    }

    /// How long ⇧⌘F waits for a handshake before routing without it.
    ///
    /// Long enough for a server that is going to answer — the ones here
    /// advertise their capabilities in the first exchange, well inside this —
    /// and short enough that a reader who pressed a key does not think the key
    /// did nothing.
    static let serverSettleTimeout: TimeInterval = 3

    /// Whether to wait at all before reading the server's answer.
    ///
    /// Only for ⇧⌘F, and only while the handshake is actually in flight. A
    /// save must never stall on the network: format-on-save runs on every ⌘S,
    /// and a reader who saves during a restart would be waiting three seconds
    /// for a file they already have.
    static func waitsForServer(
        trigger: EditorFormatTrigger,
        server: LSPServerStatus?
    ) -> Bool {
        trigger == .command && server == .starting
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
    /// - Parameter serverReturnedNothing: whether the server has already been
    ///   asked and came back with no edits. It lifts the deference, and only
    ///   that: a server that formats is still asked first.
    ///
    ///   Shell is why it exists. `bash-language-server` advertises formatting
    ///   and shells out to `shfmt`, so the deference below hands it the file —
    ///   and a server that cannot find `shfmt` on its own `PATH` answers with
    ///   an empty edit list while the tool sits installed and working. Asking
    ///   the tool afterwards costs one process on a path that had already
    ///   failed, and turns a sentence about a server into a formatted file.
    static func usesExternalFormatter(
        server: LSPServerStatus?,
        serverFormats: Bool,
        serverReturnedNothing: Bool = false
    ) -> Bool {
        guard !serverFormats || serverReturnedNothing else { return false }
        return server != .starting || serverReturnedNothing
    }
}
