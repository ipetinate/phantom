import AppKit
import Foundation

/// The question asked before a file is staged with git's conflict markers
/// still inside it.
///
/// `git add` on a conflicted path tells git the conflict is resolved — markers
/// and all. Git's refusal to commit with unmerged paths is the only thing
/// standing between a half-resolved merge and a commit carrying
/// `<<<<<<< HEAD` in it, and staging takes that refusal away.
/// `GitCenter.stageAll(in:)` and `GitCenter.commit(...)` already refuse to
/// `add -A` while git still reports a path as unmerged. This covers what that
/// refusal cannot see.
///
/// **Two gestures, two rules, and the difference is cost.**
///
/// One row — the `+` button and the menu's Stage item, which share a single
/// callback — reads its file every time, with no gate in front of it.
/// Restricting the check to `GitStatus.unmerged` would miss the path that puts
/// markers in history most often: a file holding three conflicts where the
/// reader resolves one and stages the file. From that `git add` onwards git
/// considers the path merged and never reports it as unmerged again, so every
/// later press of the same `+` button would go unguarded while two `<<<<<<<`
/// blocks sit further down the file. One gesture, one path, one file read.
///
/// Stage All would have to read every changed file to answer the same
/// question, which is not affordable on a button pressed all day. So it is
/// gated on `hasUnfinishedMerge(at:)` first: git writes markers only while it
/// has a merge, rebase, cherry-pick or revert stopped, and it removes the file
/// that says so when the operation finishes. Outside that window Stage All
/// reads nothing at all, which is nearly every press. Inside it, the reads are
/// worth their cost.
///
/// **`NSAlert` rather than SwiftUI's `confirmationDialog`**, for the reason
/// `MCPPermissionPrompt` sets out and `BaseTerminalController.confirmClose`
/// found first (Ghostty #560): a `confirmationDialog` can be closed with
/// Cmd-W, and when it is, SwiftUI updates no binding and calls nothing back.
/// Here that would leave the reader unable to tell whether they had cancelled
/// or staged, over the one operation this exists to make deliberate.
enum GitConflictStaging {
    /// One file that still holds markers, and how many it holds.
    struct ConflictedFile: Equatable, Sendable {
        /// The file's name, which is what the panel's row shows.
        let name: String
        let conflicts: Int
    }

    /// Files larger than this are staged without being read.
    ///
    /// A conflict git wrote is in a text file somebody is editing. Reading a
    /// 200 MB capture to learn it holds no markers costs more than the
    /// question is worth, and the reader waits through it.
    static let maxBytesToScan = 4 * 1024 * 1024

    // MARK: Reading files

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

    /// The files among `paths` that still hold markers, in the order given.
    ///
    /// `paths` are repository-relative, as git prints them and as
    /// `GitCenter.safePathsToStage(in:)` hands them over.
    static func conflicted(_ paths: [String], in root: String) -> [ConflictedFile] {
        let base = URL(fileURLWithPath: root)

        return paths.compactMap { path in
            let count = conflictCount(at: base.appendingPathComponent(path))
            guard count > 0 else { return nil }
            return ConflictedFile(name: (path as NSString).lastPathComponent, conflicts: count)
        }
    }

    // MARK: The gate in front of a repository-wide stage

    /// The files git writes while it has an operation stopped part-way, and
    /// removes when that operation finishes or is aborted.
    ///
    /// A revert conflicts exactly as a cherry-pick does — it is a cherry-pick
    /// of an inverted commit — so `REVERT_HEAD` is here for the same reason
    /// the other three are.
    private static let unfinishedMergeMarkers = [
        "MERGE_HEAD",
        "REBASE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
    ]

    /// Whether git has a merge, rebase, cherry-pick or revert stopped in
    /// `root`.
    ///
    /// This is the cheap answer to "can this working tree hold markers at
    /// all". Only git writes conflict markers, and it writes them only
    /// between starting one of these operations and finishing it. So a false
    /// here means no file needs reading.
    ///
    /// Files rather than `git rev-parse --verify MERGE_HEAD`, for the reason
    /// `GitCommonDir` gives about its own resolver: this sits on a button in
    /// the panel, and a process spawn per press buys a fact four
    /// `fileExists` calls already have.
    static func hasUnfinishedMerge(at root: String) -> Bool {
        guard let directory = gitDirectory(at: root) else { return false }

        return unfinishedMergeMarkers.contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Where git keeps *this* working tree's state.
    ///
    /// `.git` is a directory in an ordinary checkout and a file in a linked
    /// worktree, where it holds a `gitdir:` line pointing at that worktree's
    /// administrative directory.
    ///
    /// Not `GitCommonDir.resolve(from:)`, which answers a different question:
    /// it maps any worktree to the *main checkout*, because the worktree panel
    /// needs one key for a whole family. The state read here is per worktree —
    /// git keeps `MERGE_HEAD` beside each worktree's own `HEAD` — so resolving
    /// to the family would make a merge stopped in one worktree ask a question
    /// in another.
    static func gitDirectory(at root: String) -> URL? {
        guard !root.isEmpty else { return nil }
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue { return dotGit }

        /// Git writes an absolute path when it created the worktree itself and
        /// a relative one when the pair was moved or `--relative-paths` was
        /// asked for. A relative path is relative to the folder holding the
        /// `.git` file — the same shape `GitCommonDir.readGitDir` handles.
        let pointer = "gitdir:"
        guard let content = try? String(contentsOf: dotGit, encoding: .utf8),
              content.hasPrefix(pointer)
        else { return nil }

        let raw = content
            .dropFirst(pointer.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let resolved = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: root).appendingPathComponent(raw)
        return resolved.standardizedFileURL
    }

    /// The files a repository-wide stage would put in the index with markers
    /// still in them.
    ///
    /// Empty without reading a file when git has nothing stopped, which is the
    /// state Stage All is pressed in nearly every time. See the type's own
    /// notes for why the single-row check has no such gate.
    static func blockers(among paths: [String], in root: String) -> [ConflictedFile] {
        guard hasUnfinishedMerge(at: root) else { return [] }
        return conflicted(paths, in: root)
    }

    // MARK: What the reader is asked

    /// Names the file, because the alert arrives over a list of rows and the
    /// reader has to know which one it is about.
    static func question(for name: String) -> String {
        "Stage \u{201C}\(name)\u{201D} with its conflict markers?"
    }

    /// The same question for one gesture that stages several files.
    ///
    /// The count rather than the names, because the reader pressed one button
    /// and the first line has to say how big the answer is.
    static func question(fileCount: Int) -> String {
        "Stage \(fileCount) files that still hold conflict markers?"
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

    /// The same, for several files. Names them, so the reader can go and look
    /// before they answer.
    static func explanation(for names: [String]) -> String {
        listed(names) + " still hold \u{201C}<<<<<<<\u{201D} blocks git wrote and nobody "
            + "resolved. Staging tells git the merge is settled, so nothing refuses the next "
            + "commit and the markers go into history as ordinary lines."
    }

    /// How many names the alert prints before it starts counting instead.
    ///
    /// A merge can leave dozens, and a list that long is one nobody reads to
    /// the end — the reader would skip the sentence that says what staging
    /// costs, which is the part they are deciding on.
    static let maxNamesToList = 3

    /// The names as a sentence: `a`, `a and b`, `a, b and c`, `a, b, c and 4
    /// more`.
    static func listed(_ names: [String]) -> String {
        guard names.count > maxNamesToList else {
            guard let last = names.last else { return "" }
            let rest = names.dropLast()
            return rest.isEmpty ? last : rest.joined(separator: ", ") + " and " + last
        }

        let shown = names.prefix(maxNamesToList).joined(separator: ", ")
        return "\(shown) and \(names.count - maxNamesToList) more"
    }

    /// Whether a response to the alert stages anything.
    ///
    /// Only the first button does. Everything else leaves the index alone,
    /// including the response a sheet gives when its parent window closes
    /// under it: a question that ends without an answer has to end as a no.
    static func stages(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    // MARK: Asking

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
                ask([ConflictedFile(name: name, conflicts: conflicts)], in: window, stage: stage)
            }
        }
    }

    /// The same for a repository-wide stage, which asks once for the whole
    /// gesture rather than once per file.
    ///
    /// `paths` is what `GitCenter.stageAll(in:)` would put in the index. The
    /// gate is checked on the main actor before anything is dispatched, so the
    /// ordinary press costs four `fileExists` calls and no hop.
    @MainActor
    static func confirmingAll(
        _ paths: [String],
        under root: String,
        in window: NSWindow?,
        stage: @escaping () -> Void
    ) {
        guard hasUnfinishedMerge(at: root) else { return stage() }

        Task.detached(priority: .userInitiated) {
            let blocked = conflicted(paths, in: root)

            await MainActor.run {
                guard !blocked.isEmpty else { return stage() }
                ask(blocked, in: window, stage: stage)
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
        _ blocked: [ConflictedFile],
        in window: NSWindow?,
        stage: @escaping () -> Void
    ) {
        guard let first = blocked.first else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = blocked.count == 1
            ? question(for: first.name)
            : question(fileCount: blocked.count)
        alert.informativeText = blocked.count == 1
            ? explanation(conflicts: first.conflicts)
            : explanation(for: blocked.map(\.name))

        alert.addButton(withTitle: "Stage Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            /// Ordered out by hand, for the reason `BaseTerminalController`
            /// gives: an alert left in place costs the window its focus under
            /// Stage Manager (Ghostty #8336).
            alert.window.orderOut(nil)
            guard stages(response) else { return }
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
