import AppKit

/// Turns what a language server said into what the completion list draws.
///
/// It sits outside `Editor/Engine/` on purpose, and that placement is the
/// whole design. The engine draws `CodeCompletionItem` values and is forbidden
/// — by a test that reads its source — from learning that a language server
/// exists at all. Something still has to know both vocabularies, so it is this
/// type, and it is the only one.
///
/// **It holds state, which a pure mapping would not need.** The reason is
/// `CodeCompletionItem.resolveToken`: an opaque `Int` the host assigns and the
/// engine only ever hands back. Asking the server to finish an item means
/// sending it back the *same* object it sent us — a reconstruction silently
/// drops any field this app does not model, and a server that cannot recognise
/// the item it is given answers with that item **unchanged rather than with an
/// error**. So the rich value has to survive somewhere between the list being
/// built and a row being selected, and the token is the handle to it.
@MainActor
final class CompletionBridge {
    /// The rich items behind the tokens handed out for the current list.
    ///
    /// Replaced wholesale on every new answer rather than accumulated: an
    /// item from a superseded list cannot be resolved anyway — the server
    /// answers it unchanged and without an error — so keeping it would only
    /// preserve the ability to ask a question whose answer is a lie.
    private var resolvable: [Int: LSPCompletion] = [:]

    /// Monotonic across lists, never reused.
    ///
    /// Not an index into the current answer, which would be shorter and
    /// wrong: a token that means "row 3" starts meaning a different row the
    /// moment a new list arrives, and a resolve reply in flight across that
    /// boundary would decorate the wrong row with another symbol's
    /// documentation. Growing forever is free — it is an `Int`.
    private var nextToken = 0

    /// Whether the server for the current document answers `completionItem/
    /// resolve` at all.
    ///
    /// Kept so the row's info affordance can be hidden rather than offered
    /// and then disappointed. `kotlin-language-server` 1.3.13 declares no
    /// resolve support and ships no per-item documentation either, so for
    /// Kotlin there is permanently nothing behind that glyph — and a control
    /// that is always going to answer "nothing" should not be drawn.
    private(set) var supportsResolve = false

    func items(from outcome: LSPCompletionOutcome, in text: NSString) -> CodeCompletionAnswer {
        switch outcome {
        case .cancelled:
            return .unchanged

        case .noServer, .timedOut, .failed:
            /// An empty list, not `unchanged`: these mean the server has
            /// nothing to say, and a stale list left on screen would keep
            /// offering symbols from a file the reader has since left.
            ///
            /// Complete, because there is nothing to refine. Calling silence
            /// a guess would ask the engine to keep re-requesting from a
            /// server that is not answering.
            return .items([], isIncomplete: false)

        case .list(let list):
            let index = LSPLineIndex(text)
            resolvable.removeAll(keepingCapacity: true)

            let items = list.ordered.map { completion -> CodeCompletionItem in
                let token = nextToken
                nextToken += 1
                resolvable[token] = completion

                return CodeCompletionItem(
                    kind: CompletionKindMapping.kind(lsp: completion.kind),
                    label: completion.label,
                    detail: Self.detail(of: completion),
                    insertText: completion.insertText,
                    replaceRange: Self.replaceRange(of: completion.edit, using: index),
                    isSnippet: completion.isSnippet,
                    filterText: completion.filterText,
                    sortText: completion.sortText,
                    additionalEdits: Self.edits(completion.additionalTextEdits, using: index),
                    isPreselected: completion.preselect,
                    source: .server,
                    resolveToken: token,
                    id: completion.id
                )
            }

            return .items(items, isIncomplete: list.isIncomplete)
        }
    }

    /// The item behind a token, or nil once its list has been replaced.
    func completion(for token: Int?) -> LSPCompletion? {
        guard let token else { return nil }
        return resolvable[token]
    }

    /// The accepted row, carrying whatever the server added when asked about
    /// it — an `import` line, most of the time.
    ///
    /// The row that goes back out is the row that came in, with one property
    /// filled: the token, the identity and the text the reader chose all
    /// survive. Rebuilding it from the reply would be the mistake the
    /// specification warns about — a resolve may complete the properties the
    /// client declared it would wait for and may not change the rest, and a
    /// reply routinely omits `sortText` and `filterText` altogether.
    ///
    /// Nil for every outcome that is not an answer, because the caller does
    /// the same thing with all of them: insert the row as it stands. A server
    /// that answers no resolve, one that timed out and one whose list has been
    /// superseded differ in cause and not in consequence here.
    func item(
        _ item: CodeCompletionItem,
        finishedBy outcome: LSPResolveOutcome,
        in text: NSString
    ) -> CodeCompletionItem? {
        guard case .resolved(let completion) = outcome else { return nil }

        var finished = item
        finished.additionalEdits = Self.edits(
            completion.additionalTextEdits,
            using: LSPLineIndex(text)
        )
        return finished
    }

    func note(supportsResolve: Bool) {
        self.supportsResolve = supportsResolve
    }

    /// Folds a resolve into what the documentation card understands.
    ///
    /// Four host outcomes collapse to two card ones, and both collapses are
    /// deliberate. `.cancelled` and `.stale` are the same thing to a reader —
    /// the answer was about a row they have already moved off — and arrowing
    /// down a list produces one of them per keystroke, so drawing either as
    /// "no documentation" is a flicker on every press. `.noServer`,
    /// `.timedOut` and `.failed` differ in cause and not in consequence: the
    /// card has nothing to draw, and whether to ask again is the host's
    /// business rather than the card's.
    static func outcome(of resolve: LSPResolveOutcome) -> CodeCompletionDocPanel.Outcome {
        switch resolve {
        case .resolved(let item):
            return .resolved(item.documentation.map(documentation(of:)))
        case .stale, .cancelled:
            return .superseded
        case .unsupported:
            return .unsupported
        case .noServer, .timedOut, .failed:
            return .unanswered
        }
    }

    static func documentation(of markup: LSPMarkupContent) -> CodeDocumentation {
        CodeDocumentation(
            format: markup.kind == .markdown ? .markdown : .plainText,
            text: markup.value
        )
    }

    /// The right-hand column: what the row is, or where it comes from.
    ///
    /// `labelDetails.description` wins over `detail` when both exist, because
    /// they answer different questions and only one of them is worth the
    /// column. Advertising `labelDetailsSupport` is what makes
    /// `typescript-language-server` fill in the module an auto-import would
    /// come from, and *that* is the fact six identical overloads of `connect`
    /// need in order to be told apart — the type signature in `detail` is
    /// often the same for all six.
    static func detail(of completion: LSPCompletion) -> String? {
        if let description = completion.labelDetails?.description, !description.isEmpty {
            return description
        }
        if let detail = completion.labelDetails?.detail, !detail.isEmpty {
            return detail
        }
        return completion.detail
    }

    /// The span the item's own text replaces, in buffer offsets.
    ///
    /// Carrying it across is not politeness. `LSPCompletion.Edit` is an enum
    /// *because* a server's range routinely starts before the caret, and
    /// taking only `newText` through here is exactly what turns a
    /// dot-accessor row into `foo..bar`: the list draws `newText`, and the
    /// accept path needs both halves or it has to guess the other one from
    /// the word being typed — which is never the same thing.
    ///
    /// An `InsertReplaceEdit` is honoured at its **insert** range, the
    /// shorter of the two and the one ending at the caret. Same default VS
    /// Code ships, and the conservative direction: the replace range's extra
    /// span is text already on screen that the reader did not ask to lose.
    ///
    /// A range that does not resolve becomes `nil` rather than something
    /// clamped, for the reason spelled out on `edits(_:using:)` — the view
    /// then falls back to the word under the caret, which is a worse answer
    /// than the server's and a far better one than an offset that survived
    /// arithmetic it should not have.
    static func replaceRange(of edit: LSPCompletion.Edit, using index: LSPLineIndex) -> NSRange? {
        switch edit {
        case .insertAtCaret:
            return nil
        case .replace(let range, _):
            return index.range(of: range)
        case .insertReplace(let insert, _, _):
            return index.range(of: insert)
        }
    }

    /// Converts the server's line/character ranges into buffer offsets.
    ///
    /// An edit whose range does not resolve is **dropped rather than
    /// clamped**. Clamping would place an import statement at whatever offset
    /// happened to survive the arithmetic, which writes into the middle of
    /// some unrelated line; dropping it means the reader gets the identifier
    /// without the import, which is the same thing they get from a server
    /// that never offered one.
    static func edits(_ edits: [LSPTextEdit], using index: LSPLineIndex) -> [CodeTextEdit] {
        edits.compactMap { edit in
            guard let range = index.range(of: edit.range) else { return nil }
            return CodeTextEdit(range: range, newText: edit.newText)
        }
    }
}
