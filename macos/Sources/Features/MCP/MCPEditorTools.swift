import AppKit
import Foundation

/// The editor tools: what an agent may put on the reader's screen.
///
/// Mapping rather than construction. Every gesture here landed in 0.11.0 for
/// the split menus and the panels — `EditorCenter.open`, `openInSplit`,
/// `select` — so a tool is an argument check and one call. The one rule that
/// is not `EditorCenter`'s is that nothing in this file reads a file *back*:
/// a tool answers with a confirmation, never with the text it opened. An
/// agent that wants to read a file has its own tools for that, and a second
/// way in here would be a reading channel with no consent attached to it.
///
/// ## Permission: none of these ask, and that is a decision
///
/// The capabilities are `read` — a terminal's scrollback — and `run` — typing
/// into a shell. These tools do neither, so neither gate applies, and a third
/// capability is not invented here: the spec closed that list, and widening it
/// in a file of tools is how a consent model stops being one thing the reader
/// can hold in their head.
///
/// What is left is that these tools move what is on screen, which is real and
/// is answered three ways. They disclose nothing: the caller already runs as
/// the reader, on the reader's files, and gets back a sentence rather than
/// content. They are visible: a tab appearing is the most obvious event this
/// app has. They are reversible by hand, in one gesture each — close the tab,
/// undo the split, select the tab that was there before.
///
/// A prompt for something disclosing nothing, visible on arrival and undone
/// with one click would be a prompt that gets accepted without being read, and
/// `MCPPermissionStore` is built around not spending the reader's attention
/// that way. The prompts are for the scrollback and the shell.
///
/// None of these bring the window forward, either. The window is the caller's
/// own, and stealing focus from whatever app the reader is in is not part of
/// showing them a line — `focus_terminal` is the tool that raises a window,
/// and it is the terminals' to offer.
///
/// ## The mark `reveal_line` leaves
///
/// A revealed line also gets the calling agent's own mark in the gutter, so a
/// reader coming back to the window can see which line was pointed at and who
/// pointed. Which agent is established the same way the window is — from the
/// caller's tab, by the app — and never from what the client called itself.
/// See ``agent(inTab:)``.
///
/// It is a decoration and is treated as one: everything about it can fail
/// quietly, and none of it can turn a reveal into a refusal.
@MainActor
enum MCPEditorTools {
    static var all: [MCPToolHandler] { all(editor: MCPWindows.editor(for:)) }

    /// The tools against an editor the caller resolves.
    ///
    /// The seam every test uses: an `EditorCenter` needs no window, so handing
    /// one in covers each tool end to end — the arguments, the refusals and
    /// the layout that comes out the other side. `agent` is the second seam,
    /// for the same reason: which agent a tab is running is a fact about a
    /// directory of state files, and the mark it decides is worth asserting
    /// without one.
    static func all(
        editor: @escaping (UUID?) -> EditorCenter?,
        agent: @escaping (UUID?) -> CodingAgent? = MCPEditorTools.agent(inTab:)
    ) -> [MCPToolHandler] {
        [
            listPanes(editor),
            openFile(editor),
            openFileInSplit(editor),
            focusTab(editor),
            revealLine(editor, agent),
            closeTab(editor),
        ]
    }

    /// Which agent is calling, as the app knows it rather than as the caller
    /// says it.
    ///
    /// `MCPToolContext.clientName` is right there and is deliberately not read.
    /// It is the client's own word for itself, and a mark in the margin naming
    /// the wrong agent is worse than no mark: the whole point of the mark is
    /// that two agents working in one window stay told apart.
    ///
    /// `TabStateCenter.shared.records` is the honest answer, and it is asked
    /// directly. It is the parsed contents of the tab-state file the *surface*
    /// exported and the agent's own hook wrote its `agent=` line into, keyed by
    /// the very surface id the handshake established — so it is one lookup from
    /// what a tool already holds. `AgentTabRecord.liveAgent` is the reading of
    /// it that the restore and the sidebar's plan tag already share, ended
    /// sessions and all; answering the question a fourth way would let the four
    /// disagree.
    ///
    /// `SidebarTabModel.liveAgent` holds the same fact and is not used, because
    /// it is a copy of it: `SidebarTabManager` pushes
    /// `records[surfaceId]?.liveAgent` into the row on each refresh, so it is
    /// this value one publish later, it exists only while the window has a
    /// sidebar, and reaching it means scanning every window's rows for an id
    /// that is already in hand. `AgentAttach.targets` asks the same question of
    /// the same map, for the same reason.
    ///
    /// Nil for a tab with no agent in it, which draws no mark and refuses
    /// nothing.
    static func agent(inTab surface: UUID?) -> CodingAgent? {
        guard let surface else { return nil }
        return TabStateCenter.shared.records[surface]?.liveAgent
    }

    // MARK: The vocabulary

    /// Where a new half goes, as the model says it.
    ///
    /// `EditorDropZone` names the two horizontal sides `leading` and
    /// `trailing`, which is right for a layout that mirrors itself in a
    /// right-to-left interface and wrong for a model choosing a side: an agent
    /// asked for "leading" would have to know the reader's writing direction
    /// to know which edge it named. Left, right, up and down are what a person
    /// writes in a prompt, and this is the one place the two meet.
    enum Direction: String, CaseIterable {
        case left
        case right
        case up
        case down

        var zone: EditorDropZone {
            switch self {
            case .left: return .leading
            case .right: return .trailing
            case .up: return .top
            case .down: return .bottom
            }
        }
    }

    // MARK: The tools

    /// The cells of the grid, so an agent can name one it already made.
    ///
    /// The gap this closes: every other tool here addresses either "the cell
    /// with focus" or "a brand new cell", so an agent that split the editor
    /// had no way to refer back to the half it just created. Its only verb was
    /// *add*, and a reader who asked for two files side by side got a third
    /// pane for the second file. Naming a cell is what turns `open_file` into
    /// the merge gesture.
    private static func listPanes(_ editor: @escaping (UUID?) -> EditorCenter?) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_panes",
                description: """
                    List the cells of this window's editor: each one's id, the files it \
                    holds, and which of them it is showing. Use it before open_file \
                    whenever the reader already has a cell the file belongs in — open_file \
                    takes a “pane” id from here, and that is the whole difference between \
                    reusing a cell and dividing the editor again. Call it afresh after any \
                    split or close: a cell that runs out of files closes itself.
                    """,
                schema: MCPSchema.object([:]))
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "list_panes")))
            }

            let panes = center.tree.groups.map { group in
                JSONValue.object([
                    "id": .string(group.id.uuidString),
                    "focused": .bool(group.id == center.activeGroupID),
                    "hosts_terminal": .bool(group.hostsTerminal),
                    "showing": showing(group),
                    "files": .array(group.tabs.tabs.map { tab in
                        .object([
                            "path": .string(tab.path),
                            "name": .string(tab.name),
                            "dirty": .bool(isDirty(tab.path, in: center)),
                            "pinned": .bool(tab.isPinned),
                            "selected": .bool(group.tabs.selectedPath == tab.path),
                        ])
                    }),
                ])
            }

            answer(.json(.object([
                "panes": .array(panes),
                "count": .number(Double(panes.count)),
            ])))
        }
    }

    /// What a cell is showing: a file's path, or the terminal.
    ///
    /// The terminal is a tab like any other in this model, and exactly one
    /// cell holds it, so a cell showing it has no selected *file*. Answering
    /// null there would read as "showing nothing", which is a different fact.
    private static func showing(_ group: EditorGroup) -> JSONValue {
        if group.tabs.showsTerminal { return .string("terminal") }
        return group.tabs.selectedPath.map { .string($0) } ?? .null
    }

    /// Whether a file has edits that are not on disk.
    ///
    /// Asked of `documents` rather than of the tab's own flag, because that is
    /// the map `requestClose` consults before it puts a question to the
    /// reader. A tool that refused on one source while the tab bar drew the
    /// other would be a tool that disagrees with the dot the reader is looking
    /// at. A media file has no document and no edits.
    private static func isDirty(_ path: String, in center: EditorCenter) -> Bool {
        center.documents[path]?.isDirty == true
    }

    /// A cell id as the caller spelled it, or nil for one that is not there.
    ///
    /// An id and never a position. A cell's place in the grid changes whenever
    /// any other cell opens or closes, so "the second pane" names a different
    /// cell a moment later — and an agent acting on a stale index would put
    /// the reader's file in a pane they never pointed at. An id survives a tab
    /// moving between cells and dies with the cell itself, which is the only
    /// lifetime worth handing to a caller that thinks between calls.
    private static func pane(_ named: String, in center: EditorCenter) -> EditorGroup.ID? {
        guard let id = UUID(uuidString: named), center.tree.group(id) != nil else { return nil }
        return id
    }

    /// What an unknown cell id says.
    ///
    /// It lists the cells that do exist, because the likeliest reason an id is
    /// unknown is that its cell closed itself when its last file went — and an
    /// agent told only "no such pane" would ask for the same one again.
    static func paneRefusal(_ named: String, in center: EditorCenter, for tool: String) -> String {
        let cells = center.tree.groups
        let ids = cells.map(\.id.uuidString).joined(separator: ", ")
        return "“\(named)” is not a cell in this window's editor, so \(tool) has nowhere "
            + "to put anything. A cell closes itself when its last file closes. There "
            + "\(cells.count == 1 ? "is 1 cell" : "are \(cells.count) cells") right now: "
            + "\(ids). Call list_panes for what each one holds."
    }

    /// What `open_file` says it did, which is not always what it was asked.
    ///
    /// Reopening never duplicates: a file already open in one cell is selected
    /// where it sits rather than moved, so a `pane` naming a different cell
    /// does not get the file. Reporting the requested cell there would have
    /// the agent build its next call on a layout nobody has — the same lie the
    /// split's message already refuses to tell.
    private static func openMessage(
        _ path: String,
        wasOpen: Bool,
        requested: EditorGroup.ID?,
        holder: EditorGroup.ID?
    ) -> String {
        if let requested, let holder, requested != holder {
            return "\(path) was already open in another cell, so that is where it stayed "
                + "and its tab is now the one in front there. A file is never open in two "
                + "cells at once; close it first if it has to move."
        }
        if wasOpen { return "\(path) was already open; its tab is now the one in front." }
        if requested != nil { return "Opened \(path) in the cell you named." }
        return "Opened \(path) in this window's editor."
    }

    private static func openFile(_ editor: @escaping (UUID?) -> EditorCenter?) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "open_file",
                description: """
                    Open a file in the editor of the window this agent is running in. \
                    Use it to put a file in front of the reader: after you change it, \
                    before you explain it, or when you name it in an answer. \
                    It opens in the cell that has focus, or in the cell you name with \
                    “pane”, and types nothing into any shell. Reading is not what this \
                    is for — it answers with a confirmation, never with the file's text.
                    """,
                schema: MCPSchema.object(
                    [
                        "path": MCPSchema.string(
                            "Absolute path to the file. A leading ~ is expanded; "
                            + "a relative path is refused, because this app cannot know "
                            + "which directory you meant."),
                        "pane": MCPSchema.string(
                            "Id of the cell to open it in, from list_panes. Omit it to "
                            + "use the cell that has focus. Name one to put a second file "
                            + "beside the first instead of dividing the editor again."),
                    ],
                    required: ["path"])
            )
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "open_file")))
            }

            var requested: EditorGroup.ID?
            if let named = context.string("pane") {
                guard let id = pane(named, in: center) else {
                    return answer(.refused(paneRefusal(named, in: center, for: "open_file")))
                }
                center.focus(id)
                requested = id
            }

            switch file(context.string("path"), for: "open_file") {
            case .refused(let refusal):
                answer(.refused(refusal))
            case .file(let url):
                let wasOpen = center.isOpen(url.path)
                guard center.open(url) else {
                    return answer(.refused(openFailure(center, url: url)))
                }

                let holder = center.tree.groupHolding(url.path)
                answer(.json(.object([
                    "pane": holder.map { .string($0.uuidString) } ?? .null,
                    "message": .string(openMessage(
                        url.path, wasOpen: wasOpen, requested: requested, holder: holder)),
                ])))
            }
        }
    }

    private static func openFileInSplit(
        _ editor: @escaping (UUID?) -> EditorCenter?
    ) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "open_file_in_split",
                description: """
                    Open a file beside what the editor is already showing, dividing the \
                    pane in a direction. Use this instead of open_file when the reader \
                    has to see both at once: a test next to the code it covers, a caller \
                    next to a definition, or the file you are changing next to the \
                    terminal. Everything open stays open.
                    """,
                schema: MCPSchema.object(
                    [
                        "path": MCPSchema.string(
                            "Absolute path to the file. A leading ~ is expanded; "
                            + "a relative path is refused."),
                        "direction": MCPSchema.enumeration(
                            "Which side of the pane the file lands on.",
                            Direction.allCases.map(\.rawValue)),
                    ],
                    required: ["path", "direction"])
            )
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "open_file_in_split")))
            }

            guard let named = context.string("direction") else {
                return answer(.refused(
                    "open_file_in_split needs a “direction”: "
                    + "\(directions). Say which side the file goes on."))
            }

            guard let direction = Direction(rawValue: named.lowercased()) else {
                return answer(.refused(
                    "“\(named)” is not a direction this editor divides in. "
                    + "Use one of: \(directions)."))
            }

            switch file(context.string("path"), for: "open_file_in_split") {
            case .refused(let refusal):
                answer(.refused(refusal))
            case .file(let url):
                let cells = center.tree.groups.count
                center.openInSplit(url, zone: direction.zone)

                guard center.isOpen(url.path) else {
                    return answer(.refused(openFailure(center, url: url)))
                }

                /// The tree heals a half that ends up empty, so a lone tab
                /// asked to split out of its own cell lands back where it
                /// started. That is the layout the reader gets, so it is what
                /// the answer says — reporting a split that is not on screen
                /// would have the agent describe a pane nobody has.
                let divided = center.tree.groups.count > cells
                let holder = center.tree.groupHolding(url.path)
                answer(.json(.object([
                    "pane": holder.map { .string($0.uuidString) } ?? .null,
                    "divided": .bool(divided),
                    "message": .string(
                        divided
                            ? "Opened \(url.path) in a new cell, \(direction.rawValue) of "
                            + "the one that had focus. Pass this “pane” id to open_file to "
                            + "put the next file in that same cell, instead of dividing "
                            + "the editor again."
                            : "Opened \(url.path). The pane was not divided: the cell it "
                            + "opened in had nothing else to keep, and an empty half "
                            + "closes itself."),
                ])))
            }
        }
    }

    private static func focusTab(_ editor: @escaping (UUID?) -> EditorCenter?) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "focus_tab",
                description: """
                    Select a file the editor already has open, in whichever cell holds \
                    it. Use it to bring back a file the reader had in front of them, or \
                    to return to one you opened earlier in this session. It refuses when \
                    the file is not open; open_file is what opens one.
                    """,
                schema: MCPSchema.object(
                    ["path": MCPSchema.string("Absolute path of the open file to select.")],
                    required: ["path"])
            )
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "focus_tab")))
            }

            guard let path = absolutePath(context.string("path")) else {
                return answer(.refused(pathRefusal(context.string("path"), for: "focus_tab")))
            }

            guard center.isOpen(path) else {
                return answer(.refused(
                    "\(path) is not open in this window's editor, so there is no tab "
                    + "to select. Call open_file with it first."))
            }

            center.select(path)
            answer(.text("Selected \(path) in this window's editor."))
        }
    }

    /// Closing one tab, which is also how two cells become one.
    ///
    /// The only tool here that takes something off the reader's screen, and it
    /// exists because the agent could previously only add: asked to show two
    /// files side by side and then to tidy up, it had no verb for the second
    /// half and told the reader to drag a tab by hand. A cell whose last file
    /// closes is removed by the tree, so this is the merge gesture as well as
    /// the close one.
    ///
    /// **Unsaved edits are refused, not saved and not discarded.** Either
    /// choice would be the agent deciding what happens to work the reader
    /// typed and has not committed to disk. `requestClose` puts that question
    /// to a person for a reason, and a tool that answered it for them would be
    /// the one irreversible thing in this file. This is the same shape as
    /// `run_command` refusing a busy terminal.
    private static func closeTab(_ editor: @escaping (UUID?) -> EditorCenter?) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "close_tab",
                description: """
                    Close an open file's tab in this window's editor. Use it to undo your \
                    own clutter — a file you opened to check one thing, or a cell you \
                    split out and no longer need. Closing the last file in a cell closes \
                    that cell too, so this is also how you put two panes back into one. \
                    It refuses a file with unsaved edits rather than deciding for the \
                    reader, and it cannot close the terminal.
                    """,
                schema: MCPSchema.object(
                    ["path": MCPSchema.string("Absolute path of the open file to close.")],
                    required: ["path"])
            )
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "close_tab")))
            }

            guard let path = absolutePath(context.string("path")) else {
                return answer(.refused(pathRefusal(context.string("path"), for: "close_tab")))
            }

            guard center.isOpen(path) else {
                return answer(.refused(
                    "\(path) is not open in this window's editor, so there is no tab to "
                    + "close. Call list_panes for what is open."))
            }

            guard !isDirty(path, in: center) else {
                return answer(.refused(
                    "\(path) has edits that are not saved, so it stays open. What happens "
                    + "to unsaved work is the reader's call: they close it with the tab's "
                    + "× or ⌘W, which asks them first. Nothing here saves or discards it "
                    + "for them."))
            }

            let cells = center.tree.groups.count
            center.close(path)

            answer(.text(
                center.tree.groups.count < cells
                    ? "Closed \(path). It was the last file in its cell, so that cell "
                    + "closed with it and the editor is one pane simpler."
                    : "Closed \(path)."))
        }
    }

    private static func revealLine(
        _ editor: @escaping (UUID?) -> EditorCenter?,
        _ agent: @escaping (UUID?) -> CodingAgent?
    ) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "reveal_line",
                description: """
                    Put the caret on a line of an open file and scroll the editor to it, \
                    and leave your own mark in the gutter beside that line. \
                    This is how you show code instead of describing it: the definition \
                    you found, the call site you are about to change, the line a stack \
                    trace names. Reach for it whenever an answer would otherwise quote a \
                    line number and leave the reader to find it. The file must already \
                    be open — call open_file first. Lines are one-based, as compilers \
                    and stack traces count them.
                    """,
                schema: MCPSchema.object(
                    [
                        "path": MCPSchema.string("Absolute path of the open file."),
                        "line": MCPSchema.integer(
                            "The line to reveal, one-based: the first line is 1."),
                        "column": MCPSchema.integer(
                            "Where on the line the caret goes, one-based. Defaults to 1."),
                    ],
                    required: ["path", "line"])
            )
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "reveal_line")))
            }

            guard let path = absolutePath(context.string("path")) else {
                return answer(.refused(pathRefusal(context.string("path"), for: "reveal_line")))
            }

            guard let document = center.documents[path] else {
                return answer(.refused(revealRefusal(center, path: path)))
            }

            guard let line = context.int("line") else {
                return answer(.refused(
                    "reveal_line needs a “line” argument: the one-based line to put "
                    + "the caret on."))
            }

            let lines = lineCount(of: document.currentText)
            guard line >= 1, line <= lines else {
                return answer(.refused(
                    "\(path) has \(lines) line\(lines == 1 ? "" : "s") and you asked for "
                    + "line \(line). Lines are one-based, so the last one is \(lines)."))
            }

            let column = max(1, context.int("column") ?? 1)
            let position = LSPPosition(line: line - 1, character: column - 1)

            /// The editor's own way in, the one the Git panel, the search
            /// results and go-to-definition all use. A caret moved any other
            /// way would be a second path to keep in step with this one — and
            /// the mark rides the same call for the same reason, rather than
            /// being a second write that could land without the reveal.
            ///
            /// The agent is resolved here and not checked: nil is a tab running
            /// no agent Phantom knows of, and it means a reveal with no mark
            /// on it. A missing mark must never cost the reader the jump.
            guard center.open(
                URL(fileURLWithPath: path),
                reveal: LSPRange(start: position, end: position),
                markedBy: agent(context.callerSurface))
            else {
                return answer(.refused(
                    openFailure(center, url: URL(fileURLWithPath: path))))
            }

            answer(.text("The editor is showing \(path) at line \(line)."))
        }
    }

    // MARK: What the refusals say

    private static var directions: String {
        Direction.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// The sentence for a caller with no window of its own.
    ///
    /// Says which of the two conditions failed as far as it can: an agent in
    /// somebody else's terminal never had a tab, and an agent whose tab was
    /// closed had one a moment ago. Neither is fixed by calling again, so the
    /// sentence says what would fix it instead.
    static func noEditor(for tool: String) -> String {
        "\(tool) works on the editor of the window this agent's terminal is in, and "
        + "Phantom cannot find that terminal. Run the agent in a Phantom tab; if it is "
        + "in one, the tab has since been closed and a new one is needed."
    }

    /// The absolute path a caller named, or nil when it named none.
    ///
    /// A relative path is refused rather than resolved. The app's own working
    /// directory is not the agent's, and the terminal's is not the agent's
    /// either the moment it changes directory — a guess here opens the wrong
    /// file, silently, in front of the reader.
    static func absolutePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func pathRefusal(_ path: String?, for tool: String) -> String {
        guard let path, !path.isEmpty else {
            return "\(tool) needs a “path” argument: the absolute path of the file."
        }
        return "\(tool) needs an absolute path and “\(path)” is relative. Send the whole "
            + "path, from / or ~ — this app cannot know which directory you meant."
    }

    /// What a path check settles: the file, or the sentence saying why not.
    private enum Checked {
        case file(URL)
        case refused(String)
    }

    /// The path checks every tool that opens a file makes.
    private static func file(_ path: String?, for tool: String) -> Checked {
        guard let absolute = absolutePath(path) else {
            return .refused(pathRefusal(path, for: tool))
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory) else {
            return .refused(
                "There is no file at \(absolute). Check the path, or write the file first.")
        }

        guard !isDirectory.boolValue else {
            return .refused(
                "\(absolute) is a folder, and the editor opens files. Name a file inside it.")
        }

        return .file(URL(fileURLWithPath: absolute))
    }

    /// Why the editor declined a file, in the editor's own words.
    ///
    /// Taken from `openFailure` and cleared as it is read: that value exists to
    /// raise an alert over the window, and an alert the reader has to dismiss
    /// is not what a tool call should leave behind.
    private static func openFailure(_ center: EditorCenter, url: URL) -> String {
        let verdict = center.openFailure?.verdict
        center.openFailure = nil
        let reason = verdict?.reason ?? "The editor could not open this file."
        return "\(url.path) was not opened. \(reason)"
    }

    /// Why there is no caret to move, which is two different situations.
    private static func revealRefusal(_ center: EditorCenter, path: String) -> String {
        if center.media[path] != nil {
            return "\(path) is open as an image or a PDF, which has no lines to reveal. "
                + "reveal_line works on files the editor opens as text."
        }
        return "\(path) is not open in this window's editor, so there is no caret to "
            + "move. Call open_file with it first, then reveal_line."
    }

    /// How many lines a document has, counted the way the editor numbers them.
    ///
    /// A trailing newline leaves an empty last line, and the editor draws it
    /// and lets the caret sit on it — so it counts here too. Anything else
    /// would refuse the end of half the files in a repository.
    static func lineCount(of text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
