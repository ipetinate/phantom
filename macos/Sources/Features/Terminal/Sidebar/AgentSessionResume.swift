import AppKit
import Foundation

/// Putting a restored tab back into the conversation it was holding.
///
/// The decision itself is `AgentTabRecord.resumeCommand`, a function of the
/// tab-state file and nothing else. What lives here is everything around it
/// that the decoder should not be doing: the preference check, and — only when
/// the file names an agent but no session — a trip to that agent's own session
/// store, off the main thread.
@MainActor
enum AgentSessionResume {
    /// Whether restored tabs resume their agents at all.
    static let preferenceKey = "SidebarRestoreAgentSessions"

    /// Where an id is looked for when the hooks never reported one. A settable
    /// property so a test can point it at a tree it built, and so that the
    /// lookup can be switched off entirely by handing over a store whose roots
    /// do not exist.
    static var store = AgentSessionStore.default

    /// Resumes the agent that was live in this surface when the app quit.
    ///
    /// `workingDirectory` is the directory the restored shell comes up in, and
    /// therefore the one the resume command will run in — which is exactly the
    /// directory the imprecise fallbacks would have searched. Looking the
    /// session up by it is not a heuristic about where the agent *was*; it is
    /// the same question the CLI would have asked, answered before the command
    /// is built instead of after it is typed.
    static func resume(
        surfaceId: UUID,
        workingDirectory: String?,
        in surface: Ghostty.SurfaceView
    ) {
        guard UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true,
              let contents = try? String(
                  contentsOf: TabStateCenter.stateFileURL(for: surfaceId),
                  encoding: .utf8
              )
        else { return }

        let record = AgentTabRecord(fileContents: contents)
        guard record.needsSessionLookup,
              let agent = record.agent,
              let workingDirectory, !workingDirectory.isEmpty
        else {
            // Nothing to look up, or nowhere to look: the file already names
            // the conversation, or names none and never will. Either way this
            // is the path every restore took before the store existed, and it
            // stays synchronous — a tab that can be resumed exactly should not
            // wait on a thread hop to find that out.
            if let command = AgentTabRecord.resumeCommand(forStateFileContents: contents) {
                ClaudeSession.run(command, in: surface)
            }
            return
        }

        // Off the main thread because the work is a directory listing, a
        // handful of bounded reads and possibly a SQLite open, and this runs
        // inside surface decoding — the window is not on screen yet, and every
        // millisecond spent here is a millisecond of nothing being on screen.
        //
        // Nothing races: the command is typed by `ClaudeSession.run`, which
        // waits for the shell to reach the foreground before sending anything
        // and starts that wait when it is called. Arriving late means the
        // shell was already at a prompt, not that the keystrokes were lost.
        let store = Self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak surface] in
            let resolved = store.mostRecentSessionID(
                agent: agent, workingDirectory: workingDirectory
            )

            DispatchQueue.main.async { [surface] in
                MainActor.assumeIsolated {
                    guard let surface,
                          let command = AgentTabRecord.resumeCommand(
                              forStateFileContents: contents,
                              fallbackSessionID: resolved
                          )
                    else { return }
                    ClaudeSession.run(command, in: surface)
                }
            }
        }
    }
}
