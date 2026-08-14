import Foundation
@testable import Ghostty
import Testing

/// Converting between the protocol's coordinates and the editor's.
///
/// This is the piece most worth being sure about: a mistake here misplaces
/// *every* feature at once — diagnostics underline the wrong word,
/// go-to-definition lands in the wrong place, rename edits the wrong
/// characters — rather than breaking one of them visibly.
struct LSPCoordinateTests {
    private func text(_ string: String) -> NSString { string as NSString }

    @Test func positionsAreZeroBased() {
        let source = text("let a = 1\nlet b = 2\nlet c = 3")
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 0), in: source) == 0)
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 1, character: 0), in: source) == 10)
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 2, character: 4), in: source) == 24)
    }

    @Test func offsetsConvertBack() {
        let source = text("let a = 1\nlet b = 2")
        let position = LSPTextCoordinates.position(at: 14, in: source)
        #expect(position == LSPPosition(line: 1, character: 4))
    }

    /// The bug this guards: columns are UTF-16 code units, not characters
    /// and not bytes. An accented identifier shifts every position after it
    /// on that line by one if characters are counted instead.
    @Test func columnsAreUTF16NotCharacters() {
        let source = text("let café = 1")
        // `café` is 4 characters and 4 UTF-16 units, so `=` sits at 9 in
        // both counts — but in *bytes* it would be 10, which is what a
        // byte-based implementation would send.
        let offset = LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 9), in: source)
        #expect(source.substring(with: NSRange(location: offset ?? 0, length: 1)) == "=")
    }

    /// An emoji is two UTF-16 units and one character — the case where the
    /// two counts genuinely disagree.
    @Test func charactersOutsideTheBasicPlaneCountAsTwo() {
        let source = text("let x = \"🎉\" ")
        let position = LSPTextCoordinates.position(at: 11, in: source)
        #expect(position.line == 0)
        #expect(position.character == 11)
    }

    @Test func aPositionPastTheEndClampsRatherThanCrashing() {
        let source = text("short")
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 999), in: source) == 5)
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 99, character: 0), in: source) == nil)
    }

    @Test func rangesConvertToNSRange() {
        let source = text("let a = 1\nlet b = 2")
        let range = LSPRange(
            start: LSPPosition(line: 1, character: 4),
            end: LSPPosition(line: 1, character: 5)
        )
        let converted = LSPTextCoordinates.range(of: range, in: source)
        #expect(converted == NSRange(location: 14, length: 1))
    }

    @Test func anEmptyDocumentHasOneLine() {
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 0), in: text("")) == 0)
    }
}

/// Applying what a server sends back.
struct LSPEditTests {
    private func edit(line: Int, from: Int, to: Int, text: String) -> LSPTextEdit? {
        LSPTextEdit([
            "range": [
                "start": ["line": .integer(line), "character": .integer(from)],
                "end": ["line": .integer(line), "character": .integer(to)],
            ],
            "newText": .string(text),
        ])
    }

    /// The rule that makes multi-edit responses work: every range refers to
    /// the *original* text, so applying front-to-back invalidates every
    /// position after the first edit. Descending order means each edit
    /// lands before anything that could have moved it.
    @Test func severalEditsApplyBackToFront() {
        let source = "let alpha = beta"
        let edits = [
            edit(line: 0, from: 4, to: 9, text: "one"),
            edit(line: 0, from: 12, to: 16, text: "two"),
        ].compactMap { $0 }

        #expect(LSPTextEdit.apply(edits, to: source) == "let one = two")
    }

    /// And the order the server sent them in must not matter.
    @Test func theOrderTheServerSendsThemInIsIrrelevant() {
        let source = "let alpha = beta"
        let forward = [
            edit(line: 0, from: 4, to: 9, text: "one"),
            edit(line: 0, from: 12, to: 16, text: "two"),
        ].compactMap { $0 }
        let reversed = Array(forward.reversed())

        #expect(LSPTextEdit.apply(forward, to: source) == LSPTextEdit.apply(reversed, to: source))
    }

    @Test func anInsertionIsAZeroWidthEdit() {
        let edits = [edit(line: 0, from: 3, to: 3, text: " new")].compactMap { $0 }
        #expect(LSPTextEdit.apply(edits, to: "let x") == "let new x")
    }

    @Test func noEditsLeavesTheTextAlone() {
        #expect(LSPTextEdit.apply([], to: "unchanged") == "unchanged")
    }
}

/// Reading the shapes servers actually answer with.
struct LSPResponseShapeTests {
    /// Hover is a string, an object with `value`, or an array of either —
    /// and different servers pick differently.
    @Test func hoverAcceptsEveryShape() {
        #expect(LSPCenter.hoverText(from: .string("plain")) == "plain")
        #expect(LSPCenter.hoverText(from: ["value": .string("marked")]) == "marked")
        #expect(LSPCenter.hoverText(from: [.string("a"), ["value": .string("b")]]) == "a\n\nb")
    }

    @Test func emptyHoverIsNothingRatherThanAnEmptyTooltip() {
        #expect(LSPCenter.hoverText(from: .string("")) == nil)
        #expect(LSPCenter.hoverText(from: .null) == nil)
        #expect(LSPCenter.hoverText(from: nil) == nil)
    }

    @Test func definitionAcceptsOneLocationOrMany() {
        let single: LSPValue = [
            "uri": .string("file:///a.swift"),
            "range": [
                "start": ["line": .integer(1), "character": .integer(0)],
                "end": ["line": .integer(1), "character": .integer(4)],
            ],
        ]
        #expect(LSPCenter.locations(from: single).count == 1)
        #expect(LSPCenter.locations(from: [single, single]).count == 2)
    }

    /// `LocationLink` names its target differently. A client that reads
    /// only `Location` silently does nothing on the servers that send it.
    @Test func definitionAcceptsTheLinkForm() {
        let link: LSPValue = [
            "targetUri": .string("file:///b.swift"),
            "targetSelectionRange": [
                "start": ["line": .integer(3), "character": .integer(2)],
                "end": ["line": .integer(3), "character": .integer(8)],
            ],
        ]
        let locations = LSPCenter.locations(from: link)
        #expect(locations.first?.path == "/b.swift")
        #expect(locations.first?.range.start.line == 3)
    }

    /// A `WorkspaceEdit` uses `changes` or `documentChanges`; reading only
    /// one means rename does nothing on half the servers.
    @Test func workspaceEditsComeInTwoShapes() {
        let editValue: LSPValue = [
            "range": [
                "start": ["line": .integer(0), "character": .integer(0)],
                "end": ["line": .integer(0), "character": .integer(3)],
            ],
            "newText": .string("new"),
        ]

        let changes: LSPValue = ["changes": ["file:///a.swift": [editValue]]]
        #expect(LSPCenter.workspaceEdits(from: changes)["/a.swift"]?.count == 1)

        let documentChanges: LSPValue = [
            "documentChanges": [[
                "textDocument": ["uri": .string("file:///b.swift")],
                "edits": [editValue],
            ]],
        ]
        #expect(LSPCenter.workspaceEdits(from: documentChanges)["/b.swift"]?.count == 1)
    }

    /// Absent severity means the server declined to say. Error is the safe
    /// reading: a problem shown too loudly is noticed, one shown too
    /// quietly is not.
    @Test func aDiagnosticWithoutSeverityIsTreatedAsAnError() {
        let diagnostic = LSPDiagnostic([
            "range": [
                "start": ["line": .integer(0), "character": .integer(0)],
                "end": ["line": .integer(0), "character": .integer(1)],
            ],
            "message": .string("something"),
        ])
        #expect(diagnostic?.severity == .error)
    }

    @Test func aDiagnosticWithoutAMessageIsRejected() {
        let diagnostic = LSPDiagnostic([
            "range": [
                "start": ["line": .integer(0), "character": .integer(0)],
                "end": ["line": .integer(0), "character": .integer(1)],
            ],
        ])
        #expect(diagnostic == nil)
    }

    @Test func completionsFallBackToTheLabelWhenThereIsNoInsertText() {
        let completion = LSPCompletion(["label": .string("map")])
        #expect(completion?.insertText == "map")

        let explicit = LSPCompletion([
            "label": .string("map(_:)"),
            "insertText": .string("map("),
        ])
        #expect(explicit?.insertText == "map(")
    }
}

/// Reading a completion item the way servers actually send them.
///
/// Every fixture here is measured, and the server it came from is named:
/// the two rules these assert — match on `filterText`, order by `sortText`
/// scalar-wise — are only defensible because they describe real behaviour,
/// and a fixture nobody can trace back to a server is a fixture that will be
/// "simplified" later.
struct LSPCompletionItemTests {
    private func range(_ from: Int, _ to: Int, line: Int = 4) -> LSPValue {
        [
            "start": ["line": .integer(line), "character": .integer(from)],
            "end": ["line": .integer(line), "character": .integer(to)],
        ]
    }

    private func item(_ fields: [String: LSPValue], index: Int = 0) -> LSPCompletion? {
        LSPCompletion(.object(fields), index: index)
    }

    // MARK: The range

    /// The fixture that matters most. `typescript-language-server` builds a
    /// dot-accessor item whose range covers the `.` the user just typed and
    /// whose `newText` includes it again — so inserting `newText` at the
    /// caret writes `foo..bar`. The range has to survive the parse.
    @Test func aTextEditRangeThatStartsBeforeTheCaretIsKept() throws {
        let dotAccessor = try #require(item([
            "label": .string("bar"),
            "filterText": .string(".bar"),
            "textEdit": ["range": range(9, 10), "newText": .string(".bar")],
        ]))

        guard case .replace(let edited, let newText) = dotAccessor.edit else {
            Issue.record("a textEdit must parse as a replacement, got \(dotAccessor.edit)")
            return
        }
        #expect(edited.start.character == 9, "the range starts before the caret at 10")
        #expect(edited.end.character == 10)
        #expect(newText == ".bar")
    }

    /// Understood on the way in even though `insertReplaceSupport` is
    /// deliberately not advertised: a server that sends one anyway costs
    /// nothing to honour, and reading only `range` would find none of it.
    @Test func anInsertReplaceEditIsUnderstood() throws {
        let both = try #require(item([
            "label": .string("map"),
            "textEdit": [
                "insert": range(4, 6),
                "replace": range(4, 9),
                "newText": .string("map"),
            ],
        ]))

        guard case .insertReplace(let insert, let replace, _) = both.edit else {
            Issue.record("expected an insertReplace edit, got \(both.edit)")
            return
        }
        #expect(insert.end.character == 6)
        #expect(replace.end.character == 9)
    }

    /// No range at all: the caller decides what the typed prefix was, and the
    /// case says so out loud rather than leaving a range-shaped hole.
    @Test func anItemWithoutATextEditInsertsAtTheCaret() throws {
        let plain = try #require(item(["label": .string("map"), "insertText": .string("map(")]))
        #expect(plain.edit == .insertAtCaret("map("))
    }

    // MARK: Matching versus inserting

    /// Measured: in `typescript-language-server` an optional member arrives
    /// as `label: "foo?"` with `filterText: "foo"`. Matching against the
    /// label never matches what the user typed; inserting the filter text
    /// loses the `?`.
    @Test func anOptionalMemberMatchesWithoutItsQuestionMark() throws {
        let optional = try #require(item([
            "label": .string("foo?"),
            "filterText": .string("foo"),
            "insertText": .string("foo"),
        ]))

        #expect(optional.matchText == "foo")
        #expect(optional.insertText == "foo")
        #expect(optional.label == "foo?", "the list still draws what the server labelled it")
    }

    /// And the structural half of the same rule: `filterText` can never reach
    /// the buffer, because what is inserted comes from `edit` and nothing
    /// else.
    @Test func filterTextIsNeverWhatGetsInserted() throws {
        let dotAccessor = try #require(item([
            "label": .string("bar"),
            "filterText": .string(".bar"),
        ]))
        #expect(dotAccessor.matchText == ".bar")
        #expect(dotAccessor.insertText == "bar")
    }

    // MARK: Ordering

    /// Measured: `typescript-language-server` prefixes auto-import items with
    /// `U+FFFF` for the express purpose of sinking them below everything
    /// local. A locale-aware collation treats it as ignorable and would sort
    /// this item *first* — which is why the comparison is scalar-wise.
    @Test func anAutoImportSinksBecauseOfItsSortTextPrefix() throws {
        let items = [
            try #require(item([
                "label": .string("useState"),
                "sortText": .string("\u{FFFF}useState"),
            ], index: 0)),
            try #require(item(["label": .string("user"), "sortText": .string("11")], index: 1)),
        ]
        #expect(LSPCompletion.ordered(items).map(\.label) == ["user", "useState"])
    }

    /// Measured: `kotlin-language-server` sets `sortText` to the item's own
    /// index, zero-padded to two digits — pure positional ranking, which
    /// alphabetical ordering would destroy completely.
    @Test func kotlinsZeroPaddedIndexIsRespectedOverTheAlphabet() throws {
        let items = [
            try #require(item(["label": .string("zebra"), "sortText": .string("00")], index: 0)),
            try #require(item(["label": .string("alpha"), "sortText": .string("01")], index: 1)),
            try #require(item(["label": .string("beta"), "sortText": .string("10")], index: 2)),
        ]
        #expect(LSPCompletion.ordered(items).map(\.label) == ["zebra", "alpha", "beta"])
    }

    /// Case-sensitive, deliberately: `Z` is `U+005A` and `a` is `U+0061`, so
    /// a scalar-wise comparison puts the capital first. A case-insensitive
    /// one would not, and neither server's ranking survives being folded.
    @Test func comparisonIsByScalarAndNotFolded() {
        #expect(LSPCompletion.precedes("Z", "a"))
        #expect(!LSPCompletion.precedes("a", "Z"))
        #expect(!LSPCompletion.precedes("\u{FFFF}a", "b"))
        #expect(LSPCompletion.precedes("b", "\u{FFFF}a"))
    }

    /// With no `sortText` the label is the key — and the original position is
    /// the last tie-break, because `sorted(by:)` is not guaranteed stable and
    /// two items that compare equal could otherwise swap between two calls on
    /// the same data.
    @Test func orderingFallsBackToTheLabelThenTheServersOwnOrder() throws {
        let items = [
            try #require(item(["label": .string("same")], index: 0)),
            try #require(item(["label": .string("same")], index: 1)),
            try #require(item(["label": .string("apple")], index: 2)),
        ]
        let ordered = LSPCompletion.ordered(items)
        #expect(ordered.map(\.label) == ["apple", "same", "same"])
        #expect(ordered.map(\.index) == [2, 0, 1])
    }

    // MARK: Identity

    /// `label + detail` collided for overloads, and both
    /// `typescript-language-server` and `kotlin-language-server` emit them —
    /// two rows with the same identity make a list's selection jump.
    @Test func overloadsDoNotCollideInIdentity() throws {
        let first = try #require(item([
            "label": .string("addEventListener"),
            "detail": .string("(type, listener): void"),
        ], index: 0))
        let second = try #require(item([
            "label": .string("addEventListener"),
            "detail": .string("(type, listener): void"),
        ], index: 1))

        #expect(first.id != second.id)
    }

    // MARK: The rest of the item

    /// A `$` in a plain item is a dollar sign. Treating it as a placeholder
    /// mutilates the insertion, so the format has to be read and absence has
    /// to mean plain text.
    @Test func aDollarSignIsNotASnippetWithoutInsertTextFormatTwo() throws {
        let plain = try #require(item([
            "label": .string("log"),
            "insertText": .string("console.log($1)"),
        ]))
        #expect(!plain.isSnippet)
        #expect(plain.insertTextFormat == nil)

        let snippet = try #require(item([
            "label": .string("log"),
            "insertText": .string("console.log($1)"),
            "insertTextFormat": .integer(2),
        ]))
        #expect(snippet.isSnippet)
    }

    /// Both spellings: `tags: [1]` is current, `deprecated: true` is the
    /// pre-3.15 flag servers still send. Reading one draws half the
    /// deprecated symbols as ordinary ones.
    @Test func deprecationIsReadFromBothSpellings() throws {
        let tagged = try #require(item(["label": .string("a"), "tags": [1]]))
        let flagged = try #require(item(["label": .string("a"), "deprecated": true]))
        let otherTag = try #require(item(["label": .string("a"), "tags": [2]]))
        let plain = try #require(item(["label": .string("a")]))

        #expect(tagged.isDeprecated)
        #expect(flagged.isDeprecated)
        #expect(!otherTag.isDeprecated)
        #expect(!plain.isDeprecated)
    }

    /// The origin column, which is what `labelDetailsSupport` buys.
    @Test func labelDetailsCarryWhereTheSymbolCameFrom() throws {
        let imported = try #require(item([
            "label": .string("useState"),
            "labelDetails": ["detail": .string("(initial: S)"), "description": .string("react")],
        ]))
        #expect(imported.labelDetails?.description == "react")
        #expect(imported.labelDetails?.detail == "(initial: S)")

        let plain = try #require(item(["label": .string("plain")]))
        #expect(plain.labelDetails == nil)
    }

    /// `data` is the item's identity as far as the server is concerned, and
    /// `completionItem/resolve` has to be handed back the value it was given
    /// — verbatim, nested shapes and all. A server that cannot match a
    /// resolve returns the item *unchanged rather than failing*, so a
    /// mangled round trip is an auto-import that silently does not happen.
    @Test func dataRoundTripsVerbatim() throws {
        let payload: LSPValue = [
            "cacheId": .integer(7),
            "file": .string("/src/a.ts"),
            "nested": ["offset": .integer(112), "flags": [true, false]],
        ]
        let resolvable = try #require(item(["label": .string("x"), "data": payload]))
        #expect(resolvable.data == payload)
    }

    /// The kind has to survive the parse. A renderer decides from it whether
    /// it may run `CodeHoverInfo.split(markdown:)` over the text, and that
    /// pass over something that is not markdown eats horizontal rules and
    /// reflows lines that meant to keep their breaks.
    @Test func documentationKeepsTheKindItArrivedIn() throws {
        let asString = try #require(item([
            "label": .string("a"),
            "documentation": .string("plain words"),
        ]))
        let asMarkup = try #require(item([
            "label": .string("a"),
            "documentation": ["kind": .string("markdown"), "value": .string("**bold**")],
        ]))
        let empty = try #require(item([
            "label": .string("a"),
            "documentation": .string(""),
        ]))

        #expect(asString.documentation == LSPMarkupContent(kind: .plaintext, value: "plain words"))
        #expect(asMarkup.documentation == LSPMarkupContent(kind: .markdown, value: "**bold**"))
        #expect(empty.documentation == nil, "an empty string is nothing, not an empty pane")
    }

    /// `additionalTextEdits` is where an auto-import's `import` line arrives
    /// — inline on Kotlin, and only from a resolve on TypeScript.
    @Test func additionalTextEditsAreParsed() throws {
        let withImport = try #require(item([
            "label": .string("useState"),
            "additionalTextEdits": [[
                "range": range(0, 0, line: 0),
                "newText": .string("import { useState } from \"react\"\n"),
            ]],
        ]))

        #expect(withImport.additionalTextEdits.count == 1)
        #expect(withImport.additionalTextEdits.first?.range.start.line == 0)

        let plain = try #require(item(["label": .string("x")]))
        #expect(plain.additionalTextEdits.isEmpty)
    }

    /// The item is echoed back to the server on resolve, so it is kept as it
    /// arrived rather than rebuilt from the fields this type models — a
    /// server that cannot recognise what it is handed answers with the item
    /// unchanged rather than with an error.
    @Test func theRawItemIsKeptForTheEchoBack() throws {
        let sent: LSPValue = [
            "label": .string("useState"),
            "data": ["cacheId": .integer(4)],
            "somethingWeDoNotModel": .string("keep me"),
        ]
        let parsed = try #require(LSPCompletion(sent, index: 3))
        #expect(parsed.raw == sent)
    }

    @Test func anItemWithoutALabelIsRejected() {
        #expect(item(["insertText": .string("orphan")]) == nil)
    }
}

/// Folding a `completionItem/resolve` reply back into the item that was sent.
struct LSPCompletionResolveTests {
    private func range(_ from: Int, _ to: Int) -> LSPValue {
        [
            "start": ["line": .integer(0), "character": .integer(from)],
            "end": ["line": .integer(0), "character": .integer(to)],
        ]
    }

    private func original() throws -> LSPCompletion {
        try #require(LSPCompletion([
            "label": .string("useState"),
            "sortText": .string("\u{FFFF}useState"),
            "filterText": .string("useState"),
            "detail": .string("(alias) useState"),
            "kind": .integer(3),
            "data": ["cacheId": .integer(9)],
        ], index: 4, epoch: 2))
    }

    @Test func theFourResolvableFieldsAreTaken() throws {
        let resolved = try original().merging(resolved: [
            "label": .string("useState"),
            "detail": .string("(alias) function useState<S>(…): [S, Dispatch<S>]"),
            "documentation": ["kind": .string("markdown"), "value": .string("Returns a **stateful** value.")],
            "additionalTextEdits": [[
                "range": range(0, 0),
                "newText": .string("import { useState } from \"react\"\n"),
            ]],
            "command": ["title": .string("trigger suggest"), "command": .string("editor.action.triggerSuggest")],
        ])

        #expect(resolved.detail == "(alias) function useState<S>(…): [S, Dispatch<S>]")
        #expect(resolved.documentation?.kind == .markdown)
        #expect(resolved.documentation?.value == "Returns a **stateful** value.")
        #expect(resolved.additionalTextEdits.count == 1)
        #expect(resolved.command?["command"]?.stringValue == "editor.action.triggerSuggest")
    }

    /// The reason this is a field-by-field merge and not a replacement.
    /// Servers do drop `sortText` on resolve, and the list is already drawn
    /// in that order — a whole-item swap re-ranks the list underneath the
    /// selection that asked for the resolve.
    @Test func everythingTheReplyDoesNotOwnSurvives() throws {
        let before = try original()
        let after = before.merging(resolved: [
            "label": .string("useState"),
            "documentation": .string("prose"),
        ])

        #expect(after.sortText == before.sortText)
        #expect(after.filterText == before.filterText)
        #expect(after.label == before.label)
        #expect(after.kind == before.kind)
        #expect(after.edit == before.edit)
        #expect(after.data == before.data)
        #expect(after.index == before.index)
        #expect(after.epoch == before.epoch)
        #expect(after.id == before.id)
    }

    /// A reply that says nothing about a field keeps what the item had. The
    /// common shape: ts-ls answers a resolve it cannot match with the item
    /// it was given, so an over-eager merge would blank out fields that were
    /// already correct.
    @Test func anOmittedFieldKeepsTheOriginalValue() throws {
        let before = try original()
        let after = before.merging(resolved: ["label": .string("useState")])

        #expect(after.detail == "(alias) useState")
        #expect(after.documentation == nil)
        #expect(after.additionalTextEdits.isEmpty)
    }

    @Test func anExplicitNullDoesNotClearAField() throws {
        let before = try original()
        let after = before.merging(resolved: [
            "detail": .null,
            "documentation": .null,
            "command": .null,
        ])

        #expect(after.detail == "(alias) useState")
        #expect(after.documentation == nil)
        #expect(after.command == nil)
    }

    /// The epoch gate, as a value question. A resolve carrying an id from a
    /// list the server has already reset out of its cache comes back
    /// *unchanged and without an error*, which is indistinguishable from a
    /// server that had nothing to add — so the only way to tell them apart
    /// is never to send the second one.
    @Test func anItemKnowsWhichListItCameFrom() throws {
        let item = try original()

        #expect(item.isCurrent(inEpoch: 2))
        #expect(!item.isCurrent(inEpoch: 3))
        #expect(!item.isCurrent(inEpoch: 0))
    }

    @Test func everyItemInAListCarriesTheListsEpoch() {
        let list = LSPCompletionList(
            ["items": [["label": .string("a")], ["label": .string("b")]]],
            epoch: 7
        )
        #expect(list.items.map(\.epoch) == [7, 7])
    }
}

/// Reading a whole `CompletionList`.
struct LSPCompletionListTests {
    private func range(_ from: Int, _ to: Int) -> LSPValue {
        [
            "start": ["line": .integer(0), "character": .integer(from)],
            "end": ["line": .integer(0), "character": .integer(to)],
        ]
    }

    /// A server answers with a bare array or with `{ items: [...] }`, and
    /// handling one of them silently offers nothing on half of them.
    @Test func bothShapesOfAnswerParse() {
        let bare: LSPValue = [["label": .string("a")], ["label": .string("b")]]
        #expect(LSPCompletionList(bare).items.count == 2)

        let wrapped: LSPValue = ["items": [["label": .string("a")]]]
        #expect(LSPCompletionList(wrapped).items.count == 1)
    }

    /// Discarded entirely before, which turns every re-request into a local
    /// re-filter of a list the server already said was a guess.
    @Test func isIncompleteIsNotThrownAway() {
        let incomplete: LSPValue = ["isIncomplete": true, "items": [["label": .string("a")]]]
        #expect(LSPCompletionList(incomplete).isIncomplete)

        let complete: LSPValue = ["items": [["label": .string("a")]]]
        #expect(!LSPCompletionList(complete).isIncomplete)
        #expect(!LSPCompletionList([["label": .string("a")]]).isIncomplete)
    }

    /// `itemDefaults` is honoured on the way in even though it is
    /// deliberately not advertised — a server that sends them unbidden costs
    /// nothing to obey, and the range in them is the one an item then has no
    /// other way to carry.
    @Test func itemDefaultsFillInWhatTheItemsLeftOut() throws {
        let list = LSPCompletionList([
            "itemDefaults": [
                "editRange": range(4, 7),
                "insertTextFormat": .integer(2),
                "commitCharacters": [.string(".")],
                "data": ["cacheId": .integer(3)],
            ],
            "items": [["label": .string("value"), "textEditText": .string("valueOf")]],
        ])

        let item = try #require(list.items.first)
        #expect(item.edit == .replace(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 4),
                end: LSPPosition(line: 0, character: 7)
            ),
            newText: "valueOf"
        ))
        #expect(item.insertTextFormat == 2)
        #expect(item.commitCharacters == ["."])
        #expect(item.data == ["cacheId": .integer(3)])
    }

    /// An item's own fields win over the list's defaults.
    @Test func anItemsOwnEditWinsOverTheDefaultRange() throws {
        let list = LSPCompletionList([
            "itemDefaults": ["editRange": range(0, 1)],
            "items": [[
                "label": .string("x"),
                "textEdit": ["range": range(4, 9), "newText": .string("x")],
            ]],
        ])

        guard case .replace(let edited, _) = try #require(list.items.first).edit else {
            Issue.record("expected the item's own range to be used")
            return
        }
        #expect(edited.start.character == 4)
    }

    /// The index has to mean the position in what the *server* sent, since
    /// that is what its `sortText` is about — so an item that fails to parse
    /// must not renumber the ones after it.
    @Test func theIndexIsThePositionTheServerSentTheItemAt() {
        let list = LSPCompletionList([
            "items": [
                ["label": .string("first")],
                ["insertText": .string("no label, dropped")],
                ["label": .string("third")],
            ],
        ])

        #expect(list.items.map(\.label) == ["first", "third"])
        #expect(list.items.map(\.index) == [0, 2])
    }

    @Test func anEmptyAnswerIsAnEmptyList() {
        #expect(LSPCompletionList(.null).isEmpty)
        #expect(LSPCompletionList(["items": .array([])]).isEmpty)
    }
}

/// Which folder a server is rooted at.
struct LSPWorkspaceRootTests {
    /// Rooting at the repository is what makes cross-file answers possible
    /// — rooted at one file's directory, references would only ever find
    /// that directory.
    @Test func theRepositoryWins() {
        let path = URL(fileURLWithPath: #filePath).path
        let root = LSPCenter.workspaceRoot(for: path)
        #expect(FileManager.default.fileExists(atPath: root + "/.git"))
    }

    @Test func aFileOutsideAnyRepositoryUsesItsOwnFolder() {
        let root = LSPCenter.workspaceRoot(for: "/tmp/nowhere-\(UUID().uuidString)/file.swift")
        #expect(root.hasPrefix("/tmp/nowhere-"))
    }
}
