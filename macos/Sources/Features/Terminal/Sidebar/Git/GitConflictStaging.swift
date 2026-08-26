import AppKit
import Foundation

/// The question asked before a single file is staged with git's conflict
/// markers still inside it.
///
/// `git add` on a conflicted path tells git the conflict is resolved — markers
/// and all. Git's refusal to commit with unmerged paths is the only thing
/// standing between a half-resolved merge and a commit carrying
/// `<<<<<<< HEAD` in it, and staging takes that refusal away.
/// `GitCenter.stageAll(in:)` and `GitCenter.commit(...)` already refuse to
/// `add -A` over an unfinished merge; this covers the other gesture, the one
/// that stages one row — the `+` button and the menu's Stage item, which share
/// a single callback.
///
/// **Every file staged from a row is read, not only the ones git calls
/// unmerged.** Restricting the check to `GitStatus.unmerged` would miss the
/// path that puts markers in history most often: a file holding three
/// conflicts where the reader resolves one and stages the file. From that
/// `git add` onwards git considers the path merged and never reports it as
/// unmerged again, so every later press of the same `+` button would go
/// unguarded while two `<<<<<<<` blocks sit further down the file. The cost is
/// what makes this affordable — one gesture, one path, one file read — and it
/// is why the same rule would be wrong for a repository-wide stage, where it
/// would read every changed file to answer one question.
///
/// **`NSAlert` rather than SwiftUI's `confirmationDialog`**, for the reason
/// `MCPPermissionPrompt` sets out and `BaseTerminalController.confirmClose`
/// found first (Ghostty #560): a `confirmationDialog` can be closed with
/// Cmd-W, and when it is, SwiftUI updates no binding and calls nothing back.
/// Here that would leave the reader unable to tell whether they had cancelled
/// or staged, over the one operation this exists to make deliberate.
enum GitConflictStaging {
    /// Files larger than this are staged without being read.
    ///
    /// A conflict git wrote is in a text file somebody is editing. Reading a
    /// 200 MB capture to learn it holds no markers costs more than the
    /// question is worth, and the reader waits through it.
    static let maxBytesToScan = 4 * 1024 * 1024

    /// How many complete conflicts the file at `url` still holds.
    ///
    /// Zero for everything that is not a text file with markers in it: a path
    /// git reports as deleted, an untracked directory, an image, a file too
    /// large to be worth reading. None of those can hold a conflict, and each
    /// one fails a step above rather than needing a rule of its own.
    ///
    /// `EditorConflictParser` does the finding. It is a state machine because
    /// `=======` is also a Markdown heading underline, so a search for the
    /// separator reports a conflict in ordinary prose — see its own notes.
    static func conflictCount(at url: URL) -> Int {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxBytesToScan
        else { return 0 }

        guard let text = try? String(contentsOf: url, encoding: .utf8),
              EditorConflictParser.mayHoldConflict(text)
        else { return 0 }

        return EditorConflictParser.conflicts(in: text).count
    }

    /// Names the file, because the alert arrives over a list of rows and the
    /// reader has to know which one it is about.
    static func question(for name: String) -> String {
        "Stage \u{201C}\(name)\u{201D} with its conflict markers?"
    }

    /// What staging means, in the terms the reader is deciding in: what is
    /// still in the file, and what git stops doing once it is staged.
    static func explanation(conflicts: Int) -> String {
        let held = conflicts == 1
            ? "This file still holds an unresolved conflict: a \u{201C}<<<<<<<\u{201D} block "
                + "git wrote and nobody resolved."
            : "This file still holds \(conflicts) unresolved conflicts: \u{201C}<<<<<<<\u{201D} "
                + "blocks git wrote and nobody resolved."

        return held + " Staging it tells git the merge is settled, so nothing refuses the next "
            + "commit and the markers go into history as ordinary lines."
    }

    /// Runs `stage` — straight away when the file is clean, and after the
    /// reader says so when it is not.
    ///
    /// The read happens off the main actor. It is one file, but it is a file
    /// of unknown size on a disk of unknown speed, and it sits between a click
    /// and the thing the click does.
    @MainActor
    static func confirming(
        _ change: GitFileChange,
        at url: URL,
        in window: NSWindow?,
        stage: @escaping () -> Void
    ) {
        let name = change.name

        Task.detached(priority: .userInitiated) {
            let conflicts = conflictCount(at: url)

            await MainActor.run {
                guard conflicts > 0 else { return stage() }
                ask(name: name, conflicts: conflicts, in: window, stage: stage)
            }
        }
    }

    /// The alert, and with it the rule that no single key stages anything.
    ///
    /// AppKit gives Return to the first button it is handed, which here is the
    /// one that cannot be taken back, so that key equivalent is taken away
    /// again and Return is handed to Cancel through the window's default cell
    /// — which is also what draws Cancel as the default. The same arrangement
    /// `MCPPermissionPrompt` makes, and survivable the same way: if AppKit
    /// declines the default cell, Return does nothing at all rather than
    /// staging.
    @MainActor
    private static func ask(
        name: String,
        conflicts: Int,
        in window: NSWindow?,
        stage: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question(for: name)
        alert.informativeText = explanation(conflicts: conflicts)

        alert.addButton(withTitle: "Stage Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell

        /// Everything that is not the first button leaves the file alone,
        /// including the response a sheet gives when its parent window closes
        /// under it. A question that ends without an answer has to end as a no.
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            /// Ordered out by hand, for the reason `BaseTerminalController`
            /// gives: an alert left in place costs the window its focus under
            /// Stage Manager (Ghostty #8336).
            alert.window.orderOut(nil)
            guard response == .alertFirstButtonReturn else { return }
            stage()
        }

        /// A window already showing a sheet would queue this one behind it,
        /// and the reader would answer a question about staging after
        /// answering something unrelated. Standing on its own is better than
        /// standing in a line.
        guard let window, window.attachedSheet == nil, window.sheetParent == nil else {
            NSApp.activate(ignoringOtherApps: true)
            finish(alert.runModal())
            return
        }

        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}
