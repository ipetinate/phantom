import Foundation
@testable import Ghostty
import Testing

/// The editor half of the MCP server.
///
/// Written against a bare `EditorCenter` rather than a window, which is what
/// `MCPEditorTools.all(editor:)` exists for: every rule here — the arguments,
/// the refusals, the layout that comes out — is the tool's own, and a window
/// would only make them harder to reach.
@MainActor
struct MCPEditorToolsTests {
    private let caller = UUID()

    /// A real file, because `EditorCenter.open` loads one from disk.
    private func file(_ contents: String = "let a = 1\nlet b = 2\n") -> String {
        let path = NSTemporaryDirectory() + "phantom-mcp-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func remove(_ paths: String...) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private func tools(_ center: EditorCenter?) -> [MCPToolHandler] {
        MCPEditorTools.all(editor: { _ in center })
    }

    private func tool(_ name: String, _ center: EditorCenter?) -> MCPToolHandler {
        tools(center).first { $0.tool.name == name }!
    }

    /// Answered synchronously by every tool here: none of them asks the
    /// reader anything, which is the decision the file's own comment records.
    private func run(
        _ handler: MCPToolHandler,
        _ arguments: [String: JSONValue],
        client: AnyObject
    ) -> MCPToolResult? {
        var result: MCPToolResult?
        handler.run(
            MCPToolContext(
                callerSurface: caller,
                clientName: "test",
                client: ObjectIdentifier(client),
                arguments: arguments)
        ) { result = $0 }
        return result
    }

    private func refusal(_ result: MCPToolResult?) -> String? {
        guard case .refused(let reason)? = result else { return nil }
        return reason
    }

    private func text(_ result: MCPToolResult?) -> String? {
        guard case .text(let value)? = result else { return nil }
        return value
    }

    // MARK: What is on offer

    @Test func theToolsAreTheFourTheEditorOffers() {
        let names = tools(EditorCenter()).map(\.tool.name)
        #expect(names == ["open_file", "open_file_in_split", "focus_tab", "reveal_line"])
    }

    /// The description is the only thing deciding whether a tool is reached
    /// for at the right moment, so it has to say when — not only what.
    @Test func everyDescriptionSaysWhenToReachForIt() {
        for handler in tools(EditorCenter()) {
            let text = handler.tool.description
            let saysWhen = text.contains("Use it")
                || text.contains("Use this")
                || text.contains("Reach for it")
            #expect(saysWhen, "\(handler.tool.name) never says when to use it")
        }
    }

    @Test func everySchemaNamesWhatItCannotDoWithout() {
        let required = tools(EditorCenter()).reduce(into: [String: [JSONValue]]()) {
            $0[$1.tool.name] = $1.tool.schema.object?["required"]?.array
        }

        #expect(required["open_file"] == [.string("path")])
        #expect(required["open_file_in_split"] == [.string("path"), .string("direction")])
        #expect(required["focus_tab"] == [.string("path")])
        #expect(required["reveal_line"] == [.string("path"), .string("line")])
    }

    /// Left, right, up and down are what a person writes in a prompt; the
    /// layout's own words mirror themselves in a right-to-left interface and
    /// would leave a model guessing at an edge.
    @Test func theDirectionsAreTheOnesAModelWouldName() {
        #expect(MCPEditorTools.Direction(rawValue: "left")?.zone == .leading)
        #expect(MCPEditorTools.Direction(rawValue: "right")?.zone == .trailing)
        #expect(MCPEditorTools.Direction(rawValue: "up")?.zone == .top)
        #expect(MCPEditorTools.Direction(rawValue: "down")?.zone == .bottom)
        #expect(MCPEditorTools.Direction(rawValue: "leading") == nil)
    }

    // MARK: No window

    /// An agent in somebody else's terminal, or one whose tab has been
    /// closed. Every tool here needs a window, and none of them guesses at
    /// one: a tool that picks a window acts on the wrong one silently.
    @Test func withoutATabThereIsNoEditorToDrive() {
        let client = EditorCenter()

        for handler in tools(nil) {
            let reason = refusal(run(handler, ["path": .string("/tmp/a.swift")], client: client))
            #expect(reason?.contains(handler.tool.name) == true)
            #expect(reason?.contains("Phantom tab") == true, "\(handler.tool.name)")
        }
    }

    // MARK: open_file

    @Test func openFilePutsAFileInTheCellInFocus() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let answer = text(run(tool("open_file", center), ["path": .string(path)], client: center))

        #expect(center.isOpen(path))
        #expect(center.tabs.selectedPath == path)
        #expect(answer?.contains(path) == true)
    }

    /// The answer is a confirmation, never the text of the file. A tool that
    /// handed contents back would be a way to read with no consent attached
    /// to it — and the agent has its own tools for reading a file.
    @Test func openFileAnswersWithoutTheFilesText() {
        let center = EditorCenter()
        let path = file("let token = \"hunter2-in-the-scrollback\"\n")
        defer { remove(path) }

        let answer = text(run(tool("open_file", center), ["path": .string(path)], client: center))

        #expect(answer?.contains("hunter2") == false)
    }

    @Test func openingAFileTwiceSaysItWasAlreadyOpen() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let handler = tool("open_file", center)
        _ = run(handler, ["path": .string(path)], client: center)
        let answer = text(run(handler, ["path": .string(path)], client: center))

        #expect(answer?.contains("already open") == true)
    }

    @Test func openFileRefusesAPathThatIsNotThere() {
        let center = EditorCenter()
        let path = NSTemporaryDirectory() + "phantom-mcp-missing-\(UUID().uuidString).swift"

        let reason = refusal(run(tool("open_file", center), ["path": .string(path)], client: center))

        #expect(reason?.contains("no file at") == true)
        #expect(reason?.contains(path) == true)
        #expect(!center.isOpen(path))
    }

    /// The app's working directory is not the agent's, and the terminal's is
    /// not either the moment it changes directory. A guess opens the wrong
    /// file in front of the reader, silently.
    @Test func openFileRefusesARelativePath() {
        let center = EditorCenter()

        let reason = refusal(
            run(tool("open_file", center), ["path": .string("src/main.swift")], client: center))

        #expect(reason?.contains("absolute") == true)
        #expect(reason?.contains("src/main.swift") == true)
    }

    @Test func openFileRefusesAFolder() {
        let center = EditorCenter()
        let folder = NSTemporaryDirectory()

        let reason = refusal(
            run(tool("open_file", center), ["path": .string(folder)], client: center))

        #expect(reason?.contains("folder") == true)
    }

    @Test func openFileRefusesACallWithNoPathAtAll() {
        let center = EditorCenter()

        let reason = refusal(run(tool("open_file", center), [:], client: center))

        #expect(reason?.contains("“path”") == true)
    }

    // MARK: open_file_in_split

    @Test func openFileInSplitDividesThePane() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let answer = text(run(
            tool("open_file_in_split", center),
            ["path": .string(path), "direction": .string("right")],
            client: center))

        #expect(center.tree.groups.count == 2)
        #expect(center.isOpen(path))
        #expect(answer?.contains("right") == true)
    }

    @Test func openFileInSplitRefusesADirectionTheEditorHasNoEdgeFor() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let reason = refusal(run(
            tool("open_file_in_split", center),
            ["path": .string(path), "direction": .string("sideways")],
            client: center))

        #expect(reason?.contains("sideways") == true)
        #expect(reason?.contains("left, right, up, down") == true)
        #expect(center.tree.groups.count == 1)
    }

    @Test func openFileInSplitRefusesACallWithNoDirection() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let reason = refusal(run(
            tool("open_file_in_split", center), ["path": .string(path)], client: center))

        #expect(reason?.contains("“direction”") == true)
    }

    // MARK: focus_tab

    @Test func focusTabSelectsAFileThatIsAlreadyOpen() {
        let center = EditorCenter()
        let first = file()
        let second = file()
        defer { remove(first, second) }

        _ = center.open(URL(fileURLWithPath: first))
        _ = center.open(URL(fileURLWithPath: second))

        let answer = text(run(tool("focus_tab", center), ["path": .string(first)], client: center))

        #expect(center.tabs.selectedPath == first)
        #expect(answer?.contains(first) == true)
    }

    @Test func focusTabRefusesAFileNobodyOpened() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let reason = refusal(run(tool("focus_tab", center), ["path": .string(path)], client: center))

        #expect(reason?.contains("not open") == true)
        #expect(reason?.contains("open_file") == true)
    }

    // MARK: reveal_line

    @Test func revealLineMovesTheCaretAndCountsFromOne() {
        let center = EditorCenter()
        let path = file("one\ntwo\nthree\n")
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        let answer = text(run(
            tool("reveal_line", center),
            ["path": .string(path), "line": .number(2)],
            client: center))

        let reveal = center.documents[path]?.reveal?.range
        #expect(reveal?.start == LSPPosition(line: 1, character: 0))
        #expect(answer?.contains("line 2") == true)
    }

    @Test func revealLineTakesAColumnAndCountsThatFromOneToo() {
        let center = EditorCenter()
        let path = file("one\ntwo\nthree\n")
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            tool("reveal_line", center),
            ["path": .string(path), "line": .number(1), "column": .number(3)],
            client: center)

        #expect(center.documents[path]?.reveal?.range.start == LSPPosition(line: 0, character: 2))
    }

    @Test func revealLineRefusesALinePastTheEndAndSaysHowLongTheFileIs() {
        let center = EditorCenter()
        let path = file("one\ntwo\n")
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        let reason = refusal(run(
            tool("reveal_line", center),
            ["path": .string(path), "line": .number(99)],
            client: center))

        #expect(reason?.contains("99") == true)
        #expect(reason?.contains("3 lines") == true)
    }

    @Test func revealLineRefusesLineZeroBecauseLinesStartAtOne() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        let reason = refusal(run(
            tool("reveal_line", center),
            ["path": .string(path), "line": .number(0)],
            client: center))

        #expect(reason?.contains("one-based") == true)
    }

    @Test func revealLineRefusesAFileThatIsNotOpen() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }

        let reason = refusal(run(
            tool("reveal_line", center),
            ["path": .string(path), "line": .number(1)],
            client: center))

        #expect(reason?.contains("open_file") == true)
    }

    @Test func revealLineRefusesACallWithNoLine() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        let reason = refusal(run(tool("reveal_line", center), ["path": .string(path)], client: center))

        #expect(reason?.contains("“line”") == true)
    }

    /// The editor draws the empty line a trailing newline leaves and lets the
    /// caret sit on it, so it counts. Anything else refuses the end of half
    /// the files in a repository.
    @Test func theLastLineOfAFileEndingInANewlineStillCounts() {
        #expect(MCPEditorTools.lineCount(of: "a\nb\n") == 3)
        #expect(MCPEditorTools.lineCount(of: "a\nb") == 2)
        #expect(MCPEditorTools.lineCount(of: "") == 1)
    }

    // MARK: Paths

    @Test func aTildeIsExpandedAndAnythingRelativeIsRefused() {
        let home = NSHomeDirectory()
        #expect(MCPEditorTools.absolutePath("~/a.swift") == home + "/a.swift")
        #expect(MCPEditorTools.absolutePath("/tmp/../a.swift") == "/a.swift")
        #expect(MCPEditorTools.absolutePath("a.swift") == nil)
        #expect(MCPEditorTools.absolutePath("") == nil)
        #expect(MCPEditorTools.absolutePath(nil) == nil)
    }
}
