import Foundation
@testable import Ghostty
import Testing

/// The seam between what a server said and what the list draws.
///
/// Everything here is a static or a value; nothing touches a window. The
/// cases worth having are the ones where the obvious implementation is
/// wrong — a cancelled answer read as an empty one, an unresolvable range
/// clamped instead of dropped, and a token reused across lists.
@MainActor
struct CompletionBridgeTests {
    private func range(_ from: Int, _ to: Int, line: Int = 0) -> LSPValue {
        [
            "start": ["line": .integer(line), "character": .integer(from)],
            "end": ["line": .integer(line), "character": .integer(to)],
        ]
    }

    private func list(_ items: [LSPValue]) -> LSPCompletionOutcome {
        .list(LSPCompletionList(
            items: items.enumerated().compactMap { LSPCompletion($1, index: $0) },
            isIncomplete: false,
            itemDefaults: nil
        ))
    }

    private let text = "const a = 1\n" as NSString

    // MARK: The distinction the whole enum exists for

    /// A cancelled request is not an empty answer, and reading it as one is
    /// visible rather than theoretical: typing quickly cancels the previous
    /// request on the server, so this arrives between most pairs of
    /// keystrokes. Drawn as "no suggestions", the list blanks on exactly the
    /// characters that should be narrowing it.
    @Test func aCancelledRequestLeavesTheListAlone() {
        let bridge = CompletionBridge()
        #expect(bridge.items(from: .cancelled, in: text) == .unchanged)
    }

    /// The mirror image, and the reason `unchanged` cannot simply be the
    /// answer for everything unhelpful: these mean the server has nothing to
    /// offer here, and a list left on screen would keep suggesting symbols
    /// for a context that no longer exists.
    @Test func anUnansweredRequestClearsTheList() {
        let bridge = CompletionBridge()
        #expect(bridge.items(from: .noServer, in: text) == .items([]))
        #expect(bridge.items(from: .timedOut, in: text) == .items([]))
        #expect(bridge.items(from: .failed("boom"), in: text) == .items([]))
    }

    /// An empty list from a server that *did* answer is still an answer.
    @Test func anEmptyAnswerIsItemsAndNotUnchanged() {
        let bridge = CompletionBridge()
        #expect(bridge.items(from: list([]), in: text) == .items([]))
    }

    // MARK: Tokens

    /// The token is the only way back to the server's own object, and that
    /// object is what a resolve has to be handed: rebuilt from the fields
    /// this app models, it drops the rest, and a server that cannot match the
    /// item it receives answers with that item **unchanged rather than with
    /// an error**.
    @Test func everyItemCarriesATokenBackToTheServersOwnValue() throws {
        let bridge = CompletionBridge()
        guard case .items(let items) = bridge.items(
            from: list([["label": .string("connect")]]),
            in: text
        ) else {
            Issue.record("expected a list")
            return
        }

        let token = try #require(items.first?.resolveToken)
        #expect(bridge.completion(for: token)?.label == "connect")
    }

    /// Tokens are never reused across lists.
    ///
    /// An index into the current answer would be shorter and wrong: it starts
    /// meaning a different row the moment a new list arrives, so a resolve
    /// reply still in flight across that boundary would decorate one row with
    /// another symbol's documentation.
    @Test func aTokenFromASupersededListResolvesToNothing() throws {
        let bridge = CompletionBridge()

        guard case .items(let first) = bridge.items(
            from: list([["label": .string("alpha")]]),
            in: text
        ) else {
            Issue.record("expected a list")
            return
        }
        let stale = try #require(first.first?.resolveToken)

        guard case .items(let second) = bridge.items(
            from: list([["label": .string("beta")]]),
            in: text
        ) else {
            Issue.record("expected a list")
            return
        }
        let fresh = try #require(second.first?.resolveToken)

        #expect(stale != fresh)
        #expect(bridge.completion(for: stale) == nil)
        #expect(bridge.completion(for: fresh)?.label == "beta")
    }

    // MARK: The detail column

    /// `labelDetails.description` beats `detail`, because they answer
    /// different questions and only one is worth the column. Six overloads of
    /// `connect` share a type signature; what tells them apart is where each
    /// comes from, and advertising `labelDetailsSupport` is what makes
    /// `typescript-language-server` say so.
    @Test func theOriginWinsTheDetailColumn() throws {
        let item = try #require(LSPCompletion([
            "label": .string("connect"),
            "detail": .string("(options: Options) => Client"),
            "labelDetails": ["description": .string("./db/client")],
        ]))

        #expect(CompletionBridge.detail(of: item) == "./db/client")
    }

    /// With no label details at all, the plain `detail` is what there is.
    @Test func detailIsUsedWhenNoOriginWasSent() throws {
        let item = try #require(LSPCompletion([
            "label": .string("connect"),
            "detail": .string("(options: Options) => Client"),
        ]))

        #expect(CompletionBridge.detail(of: item) == "(options: Options) => Client")
    }

    // MARK: The range the item replaces

    /// The regression this pair exists for: the range used to be parsed with
    /// care and then dropped **here**, so the accept path had nothing left to
    /// do but guess it from the word being typed. Measured — a
    /// `typescript-language-server` dot-accessor covers the `.` and repeats it
    /// in `newText`, and guessing writes `foo..bar`.
    @Test func aServersRangeReachesTheRowItBelongsTo() throws {
        let bridge = CompletionBridge()
        guard case .items(let items) = bridge.items(
            from: list([[
                "label": .string("bar"),
                "filterText": .string(".bar"),
                "textEdit": ["range": range(3, 4), "newText": .string(".bar")],
            ]]),
            in: text
        ) else {
            Issue.record("expected a list")
            return
        }

        #expect(items.first?.insertText == ".bar")
        #expect(items.first?.replaceRange == NSRange(location: 3, length: 1))
    }

    /// No range from the server is `nil` rather than something invented, so
    /// the view can tell "the server said nothing" from "the server said
    /// here" and fall back only in the first case.
    @Test func anItemWithoutATextEditCarriesNoRange() throws {
        let bridge = CompletionBridge()
        guard case .items(let items) = bridge.items(
            from: list([["label": .string("map"), "insertText": .string("map(")]]),
            in: text
        ) else {
            Issue.record("expected a list")
            return
        }

        #expect(items.first?.replaceRange == nil)
    }

    /// An `InsertReplaceEdit` is honoured at its **insert** range — the
    /// shorter of the two, ending at the caret. It is VS Code's default and
    /// the conservative one: the replace range's extra span is text already
    /// on screen that nobody asked to lose.
    @Test func anInsertReplaceEditIsTakenAtItsInsertRange() throws {
        let item = try #require(LSPCompletion([
            "label": .string("value"),
            "textEdit": [
                "insert": range(6, 8),
                "replace": range(6, 11),
                "newText": .string("value"),
            ],
        ]))

        #expect(CompletionBridge.replaceRange(of: item.edit, using: LSPLineIndex(text))
            == NSRange(location: 6, length: 2))
    }

    /// A range that does not resolve is dropped for the same reason an
    /// unresolvable import edit is — the view then falls back to the word
    /// under the caret, which is a worse answer than the server's and a far
    /// better one than an offset that survived arithmetic it should not have.
    @Test func aRangePastTheEndOfTheDocumentBecomesNoRangeAtAll() throws {
        let item = try #require(LSPCompletion([
            "label": .string("bar"),
            "textEdit": ["range": range(0, 4, line: 900), "newText": .string("bar")],
        ]))

        #expect(CompletionBridge.replaceRange(of: item.edit, using: LSPLineIndex(text)) == nil)
    }

    // MARK: Additional edits

    @Test func anImportEditSurvivesAsABufferRange() throws {
        let index = LSPLineIndex(text)
        let edit = try #require(LSPTextEdit([
            "range": range(0, 0),
            "newText": .string("import { a } from 'b'\n"),
        ]))

        let converted = CompletionBridge.edits([edit], using: index)
        #expect(converted.count == 1)
        #expect(converted.first?.range == NSRange(location: 0, length: 0))
    }

    /// An edit whose range does not resolve is **dropped, not clamped**.
    ///
    /// Clamping would put an import statement at whatever offset survived the
    /// arithmetic, which writes into the middle of an unrelated line. Dropping
    /// it leaves the reader with the identifier and no import, which is what a
    /// server that never offered one gives them anyway.
    @Test func anEditPastTheEndOfTheDocumentIsDroppedRatherThanClamped() throws {
        let index = LSPLineIndex(text)
        let edit = try #require(LSPTextEdit([
            "range": range(0, 0, line: 900),
            "newText": .string("import { a } from 'b'\n"),
        ]))

        #expect(CompletionBridge.edits([edit], using: index).isEmpty)
    }

    // MARK: Folding resolve outcomes onto the card

    /// Superseded and cancelled are one case to a reader: the answer was
    /// about a row they have already moved off. Arrowing down a list produces
    /// one of them per keystroke, so drawing either as "no documentation"
    /// blanks the card on every press.
    @Test func aSupersededOrCancelledResolveKeepsTheCard() {
        #expect(CompletionBridge.outcome(of: .stale) == .superseded)
        #expect(CompletionBridge.outcome(of: .cancelled) == .superseded)
    }

    /// Three failures that differ in cause and not in consequence.
    @Test func everyFailureCollapsesToUnanswered() {
        #expect(CompletionBridge.outcome(of: .noServer) == .unanswered)
        #expect(CompletionBridge.outcome(of: .timedOut) == .unanswered)
        #expect(CompletionBridge.outcome(of: .failed("boom")) == .unanswered)
    }

    /// A server that will never answer keeps its own case, because the card
    /// draws no spinner for it — `kotlin-language-server` 1.3.13 declares no
    /// resolve support and ships no per-item documentation either, so waiting
    /// is a promise it has already said it will not keep.
    @Test func unsupportedStaysItsOwnAnswer() {
        #expect(CompletionBridge.outcome(of: .unsupported) == .unsupported)
    }

    /// A server that answered and had nothing is `resolved(nil)`, which is a
    /// settled fact rather than a missing one — the card says so and stops.
    @Test func anAnswerWithNoProseIsResolvedNil() throws {
        let item = try #require(LSPCompletion(["label": .string("connect")]))
        #expect(CompletionBridge.outcome(of: .resolved(item)) == .resolved(nil))
    }

    /// The format flag travels with the text. Running the markdown path over
    /// plain text reflows paragraphs whose line breaks were the author's
    /// meaning, so the two are drawn by different paths and the kind cannot
    /// be flattened away here.
    @Test func markdownKeepsItsFormatAcrossTheBoundary() {
        let markup = LSPMarkupContent(kind: .markdown, value: "**hi**")
        #expect(CompletionBridge.documentation(of: markup)
            == CodeDocumentation(format: .markdown, text: "**hi**"))

        let plain = LSPMarkupContent(kind: .plaintext, value: "hi")
        #expect(CompletionBridge.documentation(of: plain)
            == CodeDocumentation(format: .plainText, text: "hi"))
    }
}
