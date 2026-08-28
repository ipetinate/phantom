import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The two things an agent does to a reader's editor without being asked, and
/// the switches that refuse them.
///
/// An agent calling `reveal_line` moves the viewport to a line — opening the
/// file if it was closed — and leaves its brand icon in the margin. Both are
/// useful and both happen to somebody who was reading something else, which is
/// the bar ``EditorFeatureSettings`` sets for being a setting at all.
///
/// They are two switches rather than one because they are two wants: being
/// taken to the line and having an icon left behind afterwards are separable,
/// and one control for both would make a reader who dislikes one give up the
/// other.
@MainActor
@Suite(.serialized)
struct EditorAgentAssistToggleTests {
    private let caller = UUID()

    private func file(_ contents: String = "one\ntwo\nthree\n") -> String {
        let path = NSTemporaryDirectory() + "phantom-assist-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Restores whatever the machine had, including "nothing was there" — the
    /// suite runs in the app's own host and must not leave a reader's
    /// preference behind.
    private func withFeatures(
        reveal: Bool,
        mark: Bool,
        _ body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let keys: [EditorFeatureSettings.Key] = [.agentReveal, .agentGutterMark]
        let saved = keys.map { ($0, defaults.object(forKey: $0.rawValue)) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key.rawValue)
                } else {
                    defaults.removeObject(forKey: key.rawValue)
                }
            }
        }

        EditorFeatureSettings.shared.set(.agentReveal, to: reveal)
        EditorFeatureSettings.shared.set(.agentGutterMark, to: mark)
        body()
    }

    private func revealLine(_ center: EditorCenter, agent: CodingAgent?) -> MCPToolHandler {
        MCPEditorTools
            .all(editor: { _ in center }, agent: { _ in agent })
            .first { $0.tool.name == "reveal_line" }!
    }

    private func run(
        _ handler: MCPToolHandler,
        _ arguments: [String: JSONValue],
        client: AnyObject
    ) {
        handler.run(
            MCPToolContext(
                callerSurface: caller,
                clientName: "test",
                client: ObjectIdentifier(client),
                arguments: arguments)
        ) { _ in }
    }

    // MARK: Both on, which is what every reader starts with

    @Test func bothHappenByDefault() {
        withFeatures(reveal: true, mark: true) {
            let center = EditorCenter()
            let path = file()
            defer { remove(path) }
            _ = center.open(URL(fileURLWithPath: path))

            run(revealLine(center, agent: .codex),
                ["path": .string(path), "line": .number(2)],
                client: center)

            #expect(center.documents[path]?.reveal != nil)
            #expect(center.documents[path]?.agentMark != nil)
        }
    }

    // MARK: Each refused on its own

    @Test func refusingTheScrollLeavesTheMark() {
        withFeatures(reveal: false, mark: true) {
            let center = EditorCenter()
            let path = file()
            defer { remove(path) }
            _ = center.open(URL(fileURLWithPath: path))

            run(revealLine(center, agent: .codex),
                ["path": .string(path), "line": .number(2)],
                client: center)

            #expect(center.documents[path]?.reveal == nil, "the reader's place is left alone")
            #expect(center.documents[path]?.agentMark != nil, "but the line is still named")
        }
    }

    @Test func refusingTheMarkLeavesTheScroll() {
        withFeatures(reveal: true, mark: false) {
            let center = EditorCenter()
            let path = file()
            defer { remove(path) }
            _ = center.open(URL(fileURLWithPath: path))

            run(revealLine(center, agent: .codex),
                ["path": .string(path), "line": .number(2)],
                client: center)

            #expect(center.documents[path]?.reveal != nil)
            #expect(center.documents[path]?.agentMark == nil)
        }
    }

    @Test func refusingBothLeavesTheDocumentAlone() {
        withFeatures(reveal: false, mark: false) {
            let center = EditorCenter()
            let path = file()
            defer { remove(path) }
            _ = center.open(URL(fileURLWithPath: path))

            run(revealLine(center, agent: .codex),
                ["path": .string(path), "line": .number(2)],
                client: center)

            #expect(center.documents[path]?.reveal == nil)
            #expect(center.documents[path]?.agentMark == nil)
        }
    }

    // MARK: The distinction that keeps the switch honest

    /// The same code path carries a jump to a definition and a click on a
    /// search result. Those the reader asked for *in that moment*, so the
    /// switch must not touch them — refusing one would be refusing their own
    /// click. What separates the two is whether an agent asked.
    @Test func aRevealNoAgentAskedForIsNeverRefused() {
        withFeatures(reveal: false, mark: false) {
            let center = EditorCenter()
            let path = file()
            defer { remove(path) }

            _ = center.open(
                URL(fileURLWithPath: path),
                reveal: LSPRange(
                    start: LSPPosition(line: 1, character: 0),
                    end: LSPPosition(line: 1, character: 0)))

            #expect(center.documents[path]?.reveal != nil,
                    "the reader's own jump still moves the editor")
            #expect(center.documents[path]?.agentMark == nil, "and leaves no icon")
        }
    }
}
