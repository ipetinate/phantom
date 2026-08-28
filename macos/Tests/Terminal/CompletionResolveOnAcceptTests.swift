import AppKit
@testable import Ghostty
import Testing

/// Asking the server to finish a row before the row is applied.
///
/// The auto-import bug lived here. Every capability was already declared and
/// the accept path already applied `additionalEdits` correctly — but nothing
/// ever asked for them, so for every server that computes an import line only
/// on `completionItem/resolve` the list carried none and the accept applied
/// none. Measured on `typescript-language-server`: 1097 rows, zero imports in
/// the list, one import per row when asked individually.
///
/// These cases pin the two halves that decide whether the question gets asked
/// at all, and what is allowed to come back.
struct CompletionResolveOnAcceptTests {
    private func item(
        _ label: String,
        source: CodeCompletionItem.Source = .server,
        resolveToken: Int? = 1,
        additionalEdits: [CodeTextEdit] = []
    ) -> CodeCompletionItem {
        CodeCompletionItem(
            kind: .function,
            label: label,
            additionalEdits: additionalEdits,
            source: source,
            resolveToken: resolveToken
        )
    }

    private let importEdit = CodeTextEdit(
        range: NSRange(location: 0, length: 0),
        newText: "import { WSelect } from \"@alice-health/wonderland-vue\";\n"
    )

    // MARK: Which rows are worth a second request

    /// The case the bug was: a server row with a handle and no edits on it.
    @Test func aServerRowWithNoEditsIsWorthAsking() {
        #expect(item("WSelect").mayHaveUnsentEdits)
    }

    /// Nothing produced it, so there is nobody to ask. Asking anyway would
    /// spend a round trip per accept in every file with no server at all.
    @Test func aWordScrapedOutOfTheBufferIsNotWorthAsking() {
        #expect(!item("WSelect", source: .buffer).mayHaveUnsentEdits)
    }

    /// No handle means the list it came from has been replaced. A server
    /// answers such a request with the item unchanged rather than with an
    /// error, so the round trip buys a reply that cannot be told from silence.
    @Test func aRowWhoseListHasBeenReplacedIsNotWorthAsking() {
        #expect(!item("WSelect", resolveToken: nil).mayHaveUnsentEdits)
    }

    /// A server that sent the import inline has already answered. Asking
    /// again risks a reply that omits what is already right.
    @Test func aRowThatAlreadyCarriesItsImportIsNotWorthAsking() {
        #expect(!item("WSelect", additionalEdits: [importEdit]).mayHaveUnsentEdits)
    }

    // MARK: What the reply is allowed to change

    @Test func theReplysEditsLandOnTheRow() {
        let finished = item("WSelect").finished(by: item("WSelect", additionalEdits: [importEdit]))

        #expect(finished.additionalEdits == [importEdit])
    }

    /// The row the reader looked at and chose is the row that gets inserted.
    /// A resolve may fill in what the client said it would wait for; the text
    /// to insert is not on that list, and taking it from a late reply would
    /// let the server insert a different symbol than the one on screen.
    @Test func theReplyMayNotChangeWhatGetsInserted() {
        var reply = item("WSelect", additionalEdits: [importEdit])
        reply.insertText = "WSomethingElse"
        reply.label = "WSomethingElse"

        let finished = item("WSelect").finished(by: reply)

        #expect(finished.insertText == "WSelect")
        #expect(finished.label == "WSelect")
        #expect(finished.additionalEdits == [importEdit])
    }

    /// A server that cannot recognise the item it was handed answers with
    /// that item unchanged, so identity is the only evidence the reply is
    /// about this row. A reply about another row is refused rather than
    /// merged — an import for a symbol nobody chose is worse than no import.
    @Test func aReplyAboutAnotherRowIsRefused() {
        let finished = item("WSelect").finished(by: item("WSwitch", additionalEdits: [importEdit]))

        #expect(finished.additionalEdits.isEmpty)
    }

    /// The ordinary answer from a server that had nothing to add, and from
    /// one that never answers resolve at all. It has to leave the row alone.
    @Test func noReplyLeavesTheRowAsItWas() {
        let row = item("WSelect", additionalEdits: [importEdit])

        #expect(row.finished(by: nil) == row)
    }

    /// An empty reply does not clear edits the row already had. `nil` and
    /// `[]` mean the same thing here — "nothing to add" — and reading the
    /// second as "delete what you have" would strip an import a server sent
    /// inline and then declined to repeat.
    @Test func anEmptyReplyDoesNotStripEditsTheRowAlreadyHad() {
        let row = item("WSelect", additionalEdits: [importEdit])

        #expect(row.finished(by: item("WSelect")).additionalEdits == [importEdit])
    }
}

/// The two halves joined: a row that arrived carrying no import, finished by
/// the reply, then inserted.
///
/// `CompletionAcceptTests` already pins what the buffer does with edits a row
/// *has*. This is the case that never happened before — the row has none, and
/// the import exists only in an answer that has to be folded in before the
/// insertion runs.
@MainActor
struct CompletionResolvedAcceptTests {
    /// The row as a real server sends it in a list: no import on it, and a
    /// handle to ask about it with.
    private func row(_ label: String, replacing range: NSRange) -> CodeCompletionItem {
        CodeCompletionItem(
            kind: .variable,
            label: label,
            replaceRange: range,
            source: .server,
            resolveToken: 7
        )
    }

    @Test func theImportFromTheReplyLandsWithTheIdentifier() {
        let view = CodeNSTextView()
        view.string = "const x = WSel"
        view.setSelectedRange(NSRange(location: 14, length: 0))

        let listed = row("WSelect", replacing: NSRange(location: 10, length: 4))
        #expect(listed.mayHaveUnsentEdits)

        var reply = listed
        reply.additionalEdits = [CodeTextEdit(
            range: NSRange(location: 0, length: 0),
            newText: "import { WSelect } from 'w'\n"
        )]

        view.applyCompletion(listed.finished(by: reply))

        #expect(view.string == "import { WSelect } from 'w'\nconst x = WSelect")
    }

    /// The server had nothing to add, or never answered. The identifier still
    /// goes in — an accept that waited for a reply and then dropped the whole
    /// insertion when none came would be worse than the bug it replaced.
    @Test func noReplyStillInsertsTheIdentifier() {
        let view = CodeNSTextView()
        view.string = "const x = WSel"
        view.setSelectedRange(NSRange(location: 14, length: 0))

        let listed = row("WSelect", replacing: NSRange(location: 10, length: 4))
        view.applyCompletion(listed.finished(by: nil))

        #expect(view.string == "const x = WSelect")
    }
}

/// The guard on the window between asking and inserting.
///
/// Accepting a row now waits on an answer, so for the first time there is a
/// window in which the buffer can move underneath one. The edits that arrive
/// were measured against the text as it was when the question was asked, and
/// an offset means nothing against any other text.
struct CompletionResolveStalenessTests {
    private let importEdit = CodeTextEdit(
        range: NSRange(location: 0, length: 0),
        newText: "import { WSelect } from 'w'\n"
    )

    private func row(_ label: String) -> CodeCompletionItem {
        CodeCompletionItem(kind: .variable, label: label, source: .server, resolveToken: 3)
    }

    private func reply(_ label: String) -> CodeCompletionItem {
        var item = row(label)
        item.additionalEdits = [importEdit]
        return item
    }

    @Test func anUntouchedBufferTakesTheImport() {
        let applied = CodeNSTextView.rowToApply(
            asked: row("WSelect"),
            finished: reply("WSelect"),
            textWhenAsked: "const x = WSel",
            textNow: "const x = WSel"
        )

        #expect(applied.additionalEdits == [importEdit])
    }

    /// The reader kept typing while the answer travelled. The import was
    /// computed for a document one character shorter, so it is dropped — the
    /// name still goes in, which is what they get from any server that never
    /// offered an import.
    @Test func typingDuringTheWaitDropsTheImport() {
        let applied = CodeNSTextView.rowToApply(
            asked: row("WSelect"),
            finished: reply("WSelect"),
            textWhenAsked: "const x = WSel",
            textNow: "const x = WSele"
        )

        #expect(applied.additionalEdits.isEmpty)
        #expect(applied.insertText == "WSelect")
    }

    /// A second Return, which lands a newline before the answer arrives. The
    /// offsets in the reply are measured against a document without it.
    @Test func aSecondReturnDuringTheWaitDropsTheImport() {
        let applied = CodeNSTextView.rowToApply(
            asked: row("WSelect"),
            finished: reply("WSelect"),
            textWhenAsked: "const x = WSel",
            textNow: "const x = WSel\n"
        )

        #expect(applied.additionalEdits.isEmpty)
    }

    /// A caret move is not a text change, so nothing the reply says has gone
    /// stale. Refusing here would drop imports for a reader who merely
    /// clicked, which is the common case rather than the dangerous one.
    @Test func movingTheCaretAloneKeepsTheImport() {
        let applied = CodeNSTextView.rowToApply(
            asked: row("WSelect"),
            finished: reply("WSelect"),
            textWhenAsked: "const x = WSel",
            textNow: "const x = WSel"
        )

        #expect(applied.additionalEdits == [importEdit])
    }
}
