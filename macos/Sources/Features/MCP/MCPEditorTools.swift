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
@MainActor
enum MCPEditorTools {
    static var all: [MCPToolHandler] { all(editor: MCPWindows.editor(for:)) }

    /// The tools against an editor the caller resolves.
    ///
    /// The seam every test uses: an `EditorCenter` needs no window, so handing
    /// one in covers each tool end to end — the arguments, the refusals and
    /// the layout that comes out the other side.
    static func all(editor: @escaping (UUID?) -> EditorCenter?) -> [MCPToolHandler] {
        [
            openFile(editor),
            openFileInSplit(editor),
            focusTab(editor),
            revealLine(editor),
        ]
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

    private static func openFile(_ editor: @escaping (UUID?) -> EditorCenter?) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "open_file",
                description: """
                    Open a file in the editor of the window this agent is running in. \
                    Use it to put a file in front of the reader: after you change it, \
                    before you explain it, or when you name it in an answer. \
                    It opens in the pane cell that has focus and types nothing into any \
                    shell. Reading is not what this is for — it answers with a \
                    confirmation, never with the file's text.
                    """,
                schema: MCPSchema.object(
                    [
                        "path": MCPSchema.string(
                            "Absolute path to the file. A leading ~ is expanded; "
                            + "a relative path is refused, because this app cannot know "
                            + "which directory you meant."),
                    ],
                    required: ["path"])
            )
        ) { context, answer in
            guard let center = editor(context.callerSurface) else {
                return answer(.refused(noEditor(for: "open_file")))
            }

            switch file(context.string("path"), for: "open_file") {
            case .refused(let refusal):
                answer(.refused(refusal))
            case .file(let url):
                let wasOpen = center.isOpen(url.path)
                guard center.open(url) else {
                    return answer(.refused(openFailure(center, url: url)))
                }
                answer(.text(
                    wasOpen
                        ? "\(url.path) was already open; its tab is now the one in front."
                        : "Opened \(url.path) in this window's editor."))
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
                answer(.text(
                    center.tree.groups.count > cells
                        ? "Opened \(url.path) in a new cell, \(direction.rawValue) "
                        + "of the one that had focus."
                        : "Opened \(url.path). The pane was not divided: the cell it "
                        + "opened in had nothing else to keep, and an empty half "
                        + "closes itself."))
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

    private static func revealLine(_ editor: @escaping (UUID?) -> EditorCenter?) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "reveal_line",
                description: """
                    Put the caret on a line of an open file and scroll the editor to it. \
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
            /// way would be a second path to keep in step with this one.
            guard center.open(
                URL(fileURLWithPath: path),
                reveal: LSPRange(start: position, end: position))
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
