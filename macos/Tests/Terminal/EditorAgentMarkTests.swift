import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The mark an agent leaves on the line it revealed.
///
/// Driven the way the app drives it and without a window, which is the whole
/// reason it is a value: which agent, which line, what an edit does to it and
/// what a second mark does to the first are rules, and a rule that needs a
/// screen to check is a rule nobody checks. `EditorCenter` needs no window and
/// `MCPEditorTools.all(editor:agent:)` takes both facts as arguments, so the
/// path from a tool call to a marked document is covered end to end here.
@MainActor
struct EditorAgentMarkTests {
    private let caller = UUID()

    /// A real file, because `EditorCenter.open` loads one from disk.
    private func file(_ contents: String = "one\ntwo\nthree\n") -> String {
        let path = NSTemporaryDirectory() + "phantom-mark-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func revealLine(
        _ center: EditorCenter,
        agent: CodingAgent?
    ) -> MCPToolHandler {
        MCPEditorTools
            .all(editor: { _ in center }, agent: { _ in agent })
            .first { $0.tool.name == "reveal_line" }!
    }

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

    // MARK: Which agent, which line

    @Test func revealingALineMarksItForTheAgentTheCallersTabIsRunning() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            revealLine(center, agent: .codex),
            ["path": .string(path), "line": .number(2)],
            client: center)

        #expect(center.documents[path]?.agentMark == EditorAgentMark(agent: .codex, line: 2))
    }

    /// The mark's line is read out of the range being revealed, so the two
    /// cannot name different lines. Asserted against the caret rather than
    /// against the argument, which is what makes it a claim about the pair.
    @Test func theMarkedLineIsTheOneTheCaretLandedOn() {
        let center = EditorCenter()
        let path = file("a\nb\nc\nd\n")
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            revealLine(center, agent: .claude),
            ["path": .string(path), "line": .number(3)],
            client: center)

        let document = center.documents[path]
        #expect(document?.reveal?.range.start.line == 2)
        #expect(document?.agentMark?.line == 3)
    }

    /// A tab running no agent Phantom knows of. The jump still happens; only
    /// the decoration is missing.
    @Test func aCallerWithNoKnownAgentStillGetsTheReveal() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        let result = run(
            revealLine(center, agent: nil),
            ["path": .string(path), "line": .number(2)],
            client: center)

        guard case .text = result else {
            Issue.record("reveal_line refused a call it should have answered")
            return
        }
        #expect(center.documents[path]?.reveal?.range.start.line == 1)
        #expect(center.documents[path]?.agentMark == nil)
    }

    /// Every gesture a person makes reaches `open` with no agent, and none of
    /// them should take down a mark: jumping to a definition does not make the
    /// agent's line wrong.
    @Test func aJumpWithNoAgentLeavesAnExistingMarkAlone() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        let url = URL(fileURLWithPath: path)
        _ = center.open(url)

        _ = run(
            revealLine(center, agent: .claude),
            ["path": .string(path), "line": .number(1)],
            client: center)

        let position = LSPPosition(line: 2, character: 0)
        _ = center.open(url, reveal: LSPRange(start: position, end: position))

        #expect(center.documents[path]?.agentMark == EditorAgentMark(agent: .claude, line: 1))
    }

    // MARK: One mark per file

    @Test func aSecondRevealReplacesTheFirstMarkInTheSameFile() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            revealLine(center, agent: .claude),
            ["path": .string(path), "line": .number(1)],
            client: center)
        _ = run(
            revealLine(center, agent: .opencode),
            ["path": .string(path), "line": .number(3)],
            client: center)

        #expect(center.documents[path]?.agentMark == EditorAgentMark(agent: .opencode, line: 3))
    }

    @Test func twoAgentsPointingAtTwoFilesLeaveTwoMarks() {
        let center = EditorCenter()
        let first = file()
        let second = file("x\ny\n")
        defer { remove(first); remove(second) }
        _ = center.open(URL(fileURLWithPath: first))
        _ = center.open(URL(fileURLWithPath: second))

        _ = run(
            revealLine(center, agent: .claude),
            ["path": .string(first), "line": .number(2)],
            client: center)
        _ = run(
            revealLine(center, agent: .antigravity),
            ["path": .string(second), "line": .number(1)],
            client: center)

        #expect(center.documents[first]?.agentMark == EditorAgentMark(agent: .claude, line: 2))
        #expect(
            center.documents[second]?.agentMark == EditorAgentMark(agent: .antigravity, line: 1))
    }

    // MARK: What an edit does to it

    /// One character is enough, and the mark does not try to follow the line.
    /// A mark on line 3 after a line was inserted above it points at the wrong
    /// code, which is worse than no mark.
    @Test func typingClearsTheMark() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            revealLine(center, agent: .claude),
            ["path": .string(path), "line": .number(3)],
            client: center)
        center.documents[path]?.edited("inserted\none\ntwo\nthree\n")

        #expect(center.documents[path]?.agentMark == nil)
    }

    /// The formatter, the rename, the revert and the silent reload of a clean
    /// buffer all arrive at the same function.
    @Test func replacingTheTextClearsTheMark() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            revealLine(center, agent: .codex),
            ["path": .string(path), "line": .number(2)],
            client: center)
        center.documents[path]?.replaceText("one\n", named: "Reload", undoable: false)

        #expect(center.documents[path]?.agentMark == nil)
    }

    /// Saving writes the buffer out and moves no line in it.
    @Test func savingKeepsTheMark() {
        let center = EditorCenter()
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        _ = run(
            revealLine(center, agent: .claude),
            ["path": .string(path), "line": .number(2)],
            client: center)
        let saved = center.documents[path]?.save()

        #expect(saved == true)
        #expect(center.documents[path]?.agentMark == EditorAgentMark(agent: .claude, line: 2))
    }

    /// A rename moves the file, not a line in it, so the mark travels the way
    /// the undo history does.
    @Test func aRenameCarriesTheMark() {
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/a.swift"), text: "a\nb\n")
        document.mark(.codex, atLine: 2)

        let moved = document.transferred(to: URL(fileURLWithPath: "/tmp/b.swift"))

        #expect(moved.agentMark == EditorAgentMark(agent: .codex, line: 2))
    }

    // MARK: The gutter's room for it

    /// The column is reserved on every file, marked or not, because this width
    /// is where the text starts — a column that appeared with the first mark
    /// would reflow the whole document. So hanging one must move nothing and
    /// must not report a width to the constraint that holds this view.
    @Test func hangingAMarkDoesNotChangeTheGuttersWidth() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let textView = NSTextView()
        textView.string = "one\ntwo\nthree\n"
        let scrollView = NSScrollView()
        scrollView.documentView = textView

        let gutter = CodeGutterView(
            textView: textView,
            scrollView: scrollView,
            theme: .fallback,
            font: font)
        gutter.reload()

        var reported: [CGFloat] = []
        gutter.onWidthChange = { reported.append($0) }
        let before = gutter.preferredWidth

        gutter.setMark(CodeGutterView.Mark(
            line: 2,
            image: NSImage(size: NSSize(width: 11, height: 11))))

        #expect(gutter.preferredWidth == before)
        #expect(reported.isEmpty)
        #expect(before == CodeGutterView.width(forLineCount: 4, font: font))
    }

    /// Not luck: the widest number a file can hold starts at exactly the mark
    /// column's width, and the mark ends short of that.
    @Test func theMarkNeverReachesTheWidestLineNumber() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let width = CodeGutterView.width(forLineCount: 999, font: font)
        let digits = ("999" as NSString).size(withAttributes: [.font: font]).width
        let numberStart = width - digits - CodeGutterView.numberTrailingInset

        let mark = CodeGutterView.markRect(
            in: NSRect(x: 0, y: 0, width: width, height: 16),
            size: CodeGutterView.markSize(for: font))

        #expect(mark.minX >= CodeGutterView.markLeadingInset)
        #expect(mark.maxX < numberStart)
    }

    /// The mark grows with the font so it is neither a speck in large rows nor
    /// a collision in small ones, and the clamp holds both ends.
    @Test func theMarkIsSizedFromTheFontAndClamped() {
        let small = CodeGutterView.markSize(
            for: NSFont.monospacedSystemFont(ofSize: 6, weight: .regular))
        let normal = CodeGutterView.markSize(
            for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        let huge = CodeGutterView.markSize(
            for: NSFont.monospacedSystemFont(ofSize: 40, weight: .regular))

        #expect(small == 9)
        #expect(normal == 11)
        #expect(huge == 14)
    }

    /// A row taller than the mark centres it, so a wrapped line's first row
    /// does not push the mark off the line it belongs to.
    @Test func theMarkIsCentredInItsRow() {
        let row = NSRect(x: 0, y: 100, width: 40, height: 20)
        let rect = CodeGutterView.markRect(in: row, size: 10)

        #expect(rect.midY == row.midY)
        #expect(rect.height == 10)
    }

    // MARK: Rendering, once

    /// The gutter redraws on every scroll notification. A render on that path
    /// is a render per frame, so the bitmap is made once for each agent and
    /// size and handed back after that.
    @Test func theMarkIsRenderedOncePerAgentAndSize() {
        var rendered: [(agent: CodingAgent, size: CGFloat)] = []
        let images = EditorAgentMarkImages { agent, size, _ in
            rendered.append((agent, size))
            return NSImage(size: NSSize(width: size, height: size))
        }

        let first = images.image(for: .claude, size: 11)
        let again = images.image(for: .claude, size: 11)
        #expect(first === again)
        #expect(rendered.count == 1)

        _ = images.image(for: .claude, size: 12)
        _ = images.image(for: .codex, size: 11)
        #expect(rendered.count == 3)
    }

    /// A mark that cannot be made is a mark not drawn, and nothing above this
    /// treats it as an error.
    @Test func aMarkThatCannotBeRenderedIsSimplyAbsent() {
        let images = EditorAgentMarkImages { _, _, _ in nil }

        #expect(images.image(for: .claude, size: 11) == nil)
    }

    /// Rendered pixels already carry the agent's colour. A template would be
    /// re-tinted by whatever fill colour the gutter's context holds, which is
    /// the colour the last line number was drawn in.
    @Test func aRenderedMarkIsNotATemplate() {
        guard let image = EditorAgentMarkImages.shared.image(for: .claude, size: 11) else {
            return
        }

        #expect(image.isTemplate == false)
    }
}
