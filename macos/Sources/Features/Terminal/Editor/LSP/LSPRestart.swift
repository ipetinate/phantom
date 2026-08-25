import Foundation

/// Restarting a language server, both halves of it.
///
/// Stopping a server is `LSPCenter`'s to do; telling it about the files that
/// are already open is not, because that type holds document *versions* and
/// never document text — the text belongs to the editors. A restart that only
/// did the first half would leave every open file unserved until the reader
/// touched it, which is the same "close and reopen a file" they were being
/// asked to do before any of this existed.
///
/// So the gesture lives here, above both: stop, then re-announce.
@MainActor
enum LSPRestart {
    /// What a restart did, in the reader's terms.
    struct Outcome: Equatable {
        /// How many workspaces had a running process stopped.
        let stopped: Int

        /// How many open documents were announced again afterwards.
        let reannounced: Int
    }

    static func restart(_ server: LSPServerDefinition) -> Outcome {
        finish(LSPCenter.shared.restart(server))
    }

    /// For the settings form, which holds commands rather than a definition —
    /// including one the reader has typed and not yet started anything with.
    static func restart(commands: Set<String>) -> Outcome {
        finish(LSPCenter.shared.restart(commands: commands))
    }

    private static func finish(_ stopped: Int) -> Outcome {

        /// Safe to do immediately, and only because `handleExit` checks that
        /// the process that exited is still the one under its key: the fresh
        /// server goes in now, the terminated one's exit lands afterwards and
        /// finds a key it no longer owns.
        var reannounced = 0
        for center in TerminalController.all.compactMap(\.editorCenter) {
            for (path, document) in center.documents {
                LSPCenter.shared.didOpen(path: path, text: document.currentText)
                reannounced += 1
            }
        }

        return Outcome(stopped: stopped, reannounced: reannounced)
    }
}
