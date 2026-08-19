import AppKit
@testable import Ghostty
import Testing

/// Return, when the list is open.
///
/// The report was "accepting a completion does not add a line break", and the
/// insertion path is not where that happens: whatever a row carries — plain
/// text, a multi-line snippet body, an import — is written into the storage
/// verbatim, so no newline is ever dropped from what goes in. The keystroke is
/// what is lost. A list stays open while you type, so finishing a word the
/// list is still offering leaves the reader on a row whose text is already
/// what the document says; Return was claimed as an accept, replaced
/// `connect` with `connect`, and the line break it was pressed for never
/// happened.
///
/// So Return is claimed only when accepting would change something — the same
/// condition VS Code puts on its Enter binding and on no other key — and Tab
/// still means "take this row" unconditionally.
@MainActor
struct CompletionNewlineTests {
    private func item(
        _ insertText: String,
        replacing replaceRange: NSRange? = nil,
        isSnippet: Bool = false,
        additionalEdits: [CodeTextEdit] = []
    ) -> CodeCompletionItem {
        CodeCompletionItem(
            kind: .function,
            label: insertText,
            insertText: insertText,
            replaceRange: replaceRange,
            isSnippet: isSnippet,
            additionalEdits: additionalEdits
        )
    }

    private let newline = #selector(NSResponder.insertNewline(_:))
    private let tab = #selector(NSResponder.insertTab(_:))

    // MARK: What counts as a change

    /// The word is finished and the row says the same thing: accepting it
    /// would move nothing.
    @Test func aRowMatchingTheFinishedWordChangesNothing() {
        #expect(
            CodeNSTextView.acceptChangesText(
                item: item("connect"),
                caret: 19,
                in: "let value = connect" as NSString
            ) == false
        )
    }

    /// Half a word is the ordinary case, and the one Return has always been
    /// for.
    @Test func aRowThatFinishesTheWordIsAChange() {
        #expect(
            CodeNSTextView.acceptChangesText(
                item: item("connect"),
                caret: 15,
                in: "let value = con" as NSString
            )
        )
    }

    /// Case matters: `Connect` over `connect` is an edit, and a reader who
    /// pressed Return on it asked for it.
    @Test func aRowDifferingOnlyInCaseIsAChange() {
        #expect(
            CodeNSTextView.acceptChangesText(
                item: item("Connect"),
                caret: 7,
                in: "connect" as NSString
            )
        )
    }

    /// The comparison is made over the range the row would actually replace,
    /// not over the typed word — `typescript-language-server`'s dot-accessor
    /// rows cover the `.` and repeat it in their text, so measuring the word
    /// alone would call an identical insertion a change.
    @Test func theComparisonUsesTheRangeTheRowAskedFor() {
        #expect(
            CodeNSTextView.acceptChangesText(
                item: item(".bar", replacing: NSRange(location: 3, length: 4)),
                caret: 7,
                in: "foo.bar" as NSString
            ) == false
        )
    }

    /// A snippet does something a newline does not, even when its literal text
    /// matches: it leaves tab stops behind and puts the caret on the first
    /// one.
    @Test func aSnippetIsAlwaysAChange() {
        #expect(
            CodeNSTextView.acceptChangesText(
                item: item("connect", isSnippet: true),
                caret: 7,
                in: "connect" as NSString
            )
        )
    }

    /// And an auto-import is a change somewhere else in the file, whatever the
    /// insertion at the caret comes to.
    @Test func aRowCarryingAnImportIsAlwaysAChange() {
        #expect(
            CodeNSTextView.acceptChangesText(
                item: item("connect", additionalEdits: [CodeTextEdit(
                    range: NSRange(location: 0, length: 0),
                    newText: "import a\n"
                )]),
                caret: 7,
                in: "connect" as NSString
            )
        )
    }

    // MARK: What the keyboard does with the answer

    @Test func returnIsLeftToTheDocumentWhenNothingWouldChange() {
        #expect(
            CodeNSTextView.completionCommand(
                for: newline,
                isListOpen: true,
                hasSnippetSession: false,
                acceptChangesText: false
            ) == nil
        )
    }

    @Test func returnStillAcceptsWhenThereIsSomethingToInsert() {
        #expect(
            CodeNSTextView.completionCommand(
                for: newline,
                isListOpen: true,
                hasSnippetSession: false,
                acceptChangesText: true
            ) == .accept
        )
    }

    /// Tab is not gated. It has one meaning in a list — take this row — and a
    /// Tab that fell through would indent the line instead, which is not what
    /// anybody pressed it for.
    @Test func tabAcceptsEvenWhenNothingWouldChange() {
        #expect(
            CodeNSTextView.completionCommand(
                for: tab,
                isListOpen: true,
                hasSnippetSession: false,
                acceptChangesText: false
            ) == .accept
        )
    }

    /// The gate is Return's alone: nothing else the list claims looks at it.
    @Test func movementIsUnaffectedByTheGate() {
        #expect(
            CodeNSTextView.completionCommand(
                for: #selector(NSResponder.moveDown(_:)),
                isListOpen: true,
                hasSnippetSession: false,
                acceptChangesText: false
            ) == .move(.down)
        )
        #expect(
            CodeNSTextView.completionCommand(
                for: #selector(NSResponder.cancelOperation(_:)),
                isListOpen: true,
                hasSnippetSession: false,
                acceptChangesText: false
            ) == .dismiss
        )
    }

    /// With no list open nothing is claimed either way, which is the rule the
    /// whole table rests on.
    @Test func aClosedListClaimsNothing() {
        #expect(
            CodeNSTextView.completionCommand(
                for: newline,
                isListOpen: false,
                hasSnippetSession: false,
                acceptChangesText: true
            ) == nil
        )
    }

    // MARK: The insertion itself

    /// The other half of the report, asserted so it stays true: a row whose
    /// text contains line breaks inserts them. Nothing on this path strips a
    /// newline, and this is what would catch it if something started to.
    @Test func aMultiLineRowInsertsItsLineBreaks() {
        let view = CodeNSTextView()
        view.string = "cod"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.applyCompletion(item("```swift\n\n```", replacing: NSRange(location: 0, length: 3)))

        #expect(view.string == "```swift\n\n```")
    }

    /// Including a snippet body, where the break is what makes the shape.
    @Test func aMultiLineSnippetKeepsItsLineBreaks() {
        let view = CodeNSTextView()
        view.string = "cod"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.applyCompletion(item(
            "```${1:swift}\n$0\n```",
            replacing: NSRange(location: 0, length: 3),
            isSnippet: true
        ))

        #expect(view.string == "```swift\n\n```")
    }
}
