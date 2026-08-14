import AppKit
@testable import Ghostty
import Testing

/// The completion row as a value: its icons, its colours, and the two
/// constraints that are easy to break and expensive to notice.
struct CodeCompletionItemTests {
    /// A typo in an SF Symbol name draws **nothing** — no crash, no warning, an
    /// empty icon column that looks like a layout bug. This is the only thing
    /// that catches one, and it needs no window: symbol lookup goes to the
    /// system's symbol catalogue, not to the window server.
    @Test func everyKindNamesASymbolThatExists() {
        for kind in CodeCompletionItem.Kind.allCases {
            #expect(
                NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil,
                "\(kind.rawValue) names \(kind.symbolName), which this system has no symbol for"
            )
        }
    }

    /// The rule behind the mapping is *what the highlighter would paint this
    /// identifier if it were already in the file* — which is what makes the
    /// icon beside a call the colour the call itself is drawn in. These four are
    /// the ones a reader would notice: a call, an object key, a keyword and a
    /// type are the distinctions a terminal palette can actually express.
    @Test func kindsBorrowTheColourTheirIdentifierIsPaintedIn() {
        #expect(CodeCompletionItem.Kind.function.tokenKind == .function)
        #expect(CodeCompletionItem.Kind.method.tokenKind == .function)
        #expect(CodeCompletionItem.Kind.property.tokenKind == .attribute)
        #expect(CodeCompletionItem.Kind.keyword.tokenKind == .keyword)
        #expect(CodeCompletionItem.Kind.type.tokenKind == .type)

        // A plain local has no colour of its own in the text either.
        #expect(CodeCompletionItem.Kind.variable.tokenKind == .plain)
    }

    /// The cheap sources — words from the buffer, the language's keywords —
    /// have nothing to say beyond the label, so requiring them to repeat it
    /// would be one more place for the two to drift apart.
    @Test func aLabelIsEnoughToBuildARow() {
        let item = CodeCompletionItem(kind: .text, label: "alpha", source: .buffer)

        #expect(item.insertText == "alpha")
        #expect(item.matchText == "alpha")
    }

    /// The measured TypeScript case, and the reason `filterText` and
    /// `insertText` are separate fields at all: an optional member arrives as
    /// `label: "foo?"` with `filterText: "foo"`. The query has to be matched
    /// against the filter text, and the question mark must never reach the file.
    @Test func anOptionalMemberIsMatchedWithoutItsQuestionMark() {
        let item = CodeCompletionItem(
            kind: .property,
            label: "foo?",
            insertText: "foo",
            filterText: "foo"
        )

        #expect(item.matchText == "foo")
        #expect(item.insertText == "foo")
        #expect(CodeCompletionFilter.match(query: "foo", candidate: item.matchText) != nil)
    }

    /// Two rows that differ only in where they came from are two rows, and a
    /// table that reuses views by identity would highlight the wrong one if they
    /// shared an id.
    @Test func rowsDifferingOnlyInSourceGetDifferentIdentities() {
        let fromServer = CodeCompletionItem(kind: .function, label: "connect", source: .server)
        let fromBuffer = CodeCompletionItem(kind: .function, label: "connect", source: .buffer)

        #expect(fromServer.id != fromBuffer.id)
    }

    /// Overloads differ in their detail and nothing else, which is exactly the
    /// case the old `[String]` list could not represent.
    @Test func overloadsDifferingOnlyInDetailGetDifferentIdentities() {
        let first = CodeCompletionItem(kind: .method, label: "connect", detail: "(url: string)")
        let second = CodeCompletionItem(kind: .method, label: "connect", detail: "(options: Options)")

        #expect(first.id != second.id)
    }

    /// The constraint that the compiler will not enforce here — **do not
    /// simplify this away as redundant with the `Sendable` conformance.**
    ///
    /// This item crosses an `async` boundary, so it has to be `Sendable`, and an
    /// `NSColor` field would break that. It looks like the compiler's job and it
    /// is not: this target builds in the Swift 5 language mode with no strict
    /// concurrency checking, where a `Sendable` violation is a **warning**. The
    /// type keeps compiling and the race ships. A compile-time guarantee that
    /// does not exist has to become a test, or it is not a guarantee.
    ///
    /// The temptation is real and it is next door. `CodeHoverInfo.Problem` does
    /// carry an `NSColor`, and it gets away with it because it is built and
    /// drawn in the same main-actor breath — so it reads as the local
    /// convention. Copying that shape here is precisely what this stops. Colour
    /// is derived at draw time from `Kind.tokenKind` instead.
    @Test func theItemNamesNoColour() throws {
        let source = URL(fileURLWithPath: #filePath)          // …/macos/Tests/Terminal/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()                       // …/macos
            .appendingPathComponent(
                "Sources/Features/Terminal/Editor/Engine/CodeCompletionItem.swift"
            )

        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")

        #expect(!code.contains("NSColor"), "a Sendable completion item cannot carry an NSColor")
        #expect(!code.contains("import AppKit"), "the item needs Foundation only; AppKit is how a colour gets in")
    }
}
