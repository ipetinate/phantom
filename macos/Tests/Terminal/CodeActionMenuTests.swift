import AppKit
@testable import Ghostty
import Testing

/// What ⌃. offers, and in what order.
///
/// A value in and a list of rows out, so the ordering rule is assertable
/// without a menu, a window or a language server — the same shape
/// `EditorContextCommand` is in, and for the same reason.
@MainActor
struct CodeActionMenuTests {
    private func action(
        _ id: Int,
        _ title: String,
        kind: CodeActionItem.Kind = .quickFix,
        preferred: Bool = false,
        disabled: String? = nil
    ) -> CodeActionItem {
        CodeActionItem(
            id: id,
            title: title,
            kind: kind,
            isPreferred: preferred,
            disabledReason: disabled
        )
    }

    private func titles(_ rows: [CodeActionMenu.Row]) -> [String] {
        rows.compactMap {
            if case .action(let item) = $0 { return item.title }
            return nil
        }
    }

    // MARK: Order

    /// A reader who pressed this pressed it at something underlined, so the
    /// fix for it leads.
    @Test func quickFixesComeBeforeRefactorsAndSourceActions() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "Organize Imports", kind: .source),
            action(2, "Extract Function", kind: .refactor),
            action(3, "Add Missing Import", kind: .quickFix),
        ])

        #expect(titles(rows) == ["Add Missing Import", "Extract Function", "Organize Imports"])
    }

    @Test func anUnclassifiedActionSinksToTheBottomRatherThanVanishing() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "Something", kind: .other),
            action(2, "Add Missing Import", kind: .quickFix),
        ])

        #expect(titles(rows) == ["Add Missing Import", "Something"])
    }

    /// The server's own preference leads its group, and nothing else moves.
    @Test func thePreferredActionLeadsItsGroup() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "First"),
            action(2, "Second", preferred: true),
            action(3, "Third"),
        ])

        #expect(titles(rows) == ["Second", "First", "Third"])
    }

    /// A server orders its own answers, and re-sorting them by title would
    /// throw that ordering away.
    @Test func everythingElseKeepsTheOrderItArrivedIn() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "Zebra"),
            action(2, "Alpha"),
            action(3, "Middle"),
        ])

        #expect(titles(rows) == ["Zebra", "Alpha", "Middle"])
    }

    /// Shown rather than hidden — "Add import (no default export)" tells the
    /// reader something, and a row that is silently absent does not — but
    /// under the rows that can be run.
    @Test func aDisabledActionSinksInsideItsOwnGroup() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "Cannot", disabled: "the module has no default export"),
            action(2, "Can"),
        ])

        #expect(titles(rows) == ["Can", "Cannot"])
    }

    /// Inside its own group, and not past the next one. It is still an answer
    /// about the same kind of problem, and moving it below the refactors
    /// would file it under the wrong heading.
    @Test func aDisabledQuickFixStaysAboveTheRefactors() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "Broken Fix", disabled: "no"),
            action(2, "Extract Function", kind: .refactor),
        ])

        #expect(titles(rows) == ["Broken Fix", "Extract Function"])
    }

    // MARK: Separators

    @Test func aRuleFallsWhereTheGroupChanges() {
        let rows = CodeActionMenu.rows(for: [
            action(1, "Fix"),
            action(2, "Refactor", kind: .refactor),
        ])

        #expect(rows == [
            .action(action(1, "Fix")),
            .separator,
            .action(action(2, "Refactor", kind: .refactor)),
        ])
    }

    /// No rule against nothing, at either end.
    @Test func oneGroupGetsNoRule() {
        let rows = CodeActionMenu.rows(for: [action(1, "Fix"), action(2, "Another")])

        #expect(!rows.contains(.separator))
    }

    // MARK: Nothing to offer

    /// A key that answers nothing at all cannot be told from a key that is
    /// not bound, which is the whole reason this path was built.
    @Test func anEmptyAnswerStillSaysSomething() {
        #expect(CodeActionMenu.rows(for: []) == [.message(CodeActionMenu.emptyMessage)])
    }

    // MARK: What the engine may carry out itself

    @Test func anEditToThisFileAloneIsTheEnginesToApply() {
        var item = action(1, "Fix")
        item.edits = [CodeActionEdit(range: NSRange(location: 0, length: 3), newText: "let")]

        #expect(item.isLocal)
    }

    /// The engine holds one buffer and one undo timeline. An action that
    /// reaches past them goes back to the producer whole.
    @Test func anythingReachingAnotherFileOrACommandIsNot() {
        var reaches = action(1, "Fix")
        reaches.edits = [CodeActionEdit(range: NSRange(location: 0, length: 1), newText: "x")]
        reaches.touchesOtherFiles = true

        var invokes = action(2, "Organize", kind: .source)
        invokes.edits = [CodeActionEdit(range: NSRange(location: 0, length: 1), newText: "x")]
        invokes.runsCommand = true

        #expect(!reaches.isLocal)
        #expect(!invokes.isLocal)
        #expect(!action(3, "Nothing").isLocal)
    }

    // MARK: Finishing a row

    @Test func aResolveFillsInTheEditsThatWereWithheld() {
        var asked = action(1, "Add Import")
        asked.mayHaveUnsentEdits = true

        var answered = asked
        answered.edits = [CodeActionEdit(range: NSRange(location: 0, length: 0), newText: "import X\n")]

        let finished = asked.finished(by: answered)

        #expect(finished.edits.count == 1)
        #expect(!finished.mayHaveUnsentEdits)
    }

    /// It may not rename the row under the reader who chose it by its name.
    @Test func aResolveMayNotRenameTheRow() {
        var asked = action(1, "Add Import")
        asked.mayHaveUnsentEdits = true

        var answered = asked
        answered.title = "Something Else"

        #expect(asked.finished(by: answered).title == "Add Import")
    }

    /// An answer about a different row is not this row's answer.
    @Test func anAnswerForAnotherRowIsIgnored() {
        var asked = action(1, "Add Import")
        asked.mayHaveUnsentEdits = true

        var stranger = action(9, "Add Import")
        stranger.edits = [CodeActionEdit(range: NSRange(location: 0, length: 0), newText: "no")]

        #expect(asked.finished(by: stranger).edits.isEmpty)
    }

    // MARK: Answers that arrive too late

    /// Every range a producer sends is measured against the document it last
    /// saw. If the reader typed while the answer travelled, those offsets
    /// describe a file that no longer exists — so they are dropped rather
    /// than adjusted, which is the rule `rowToApply` states for completions.
    @Test func anAnswerThatArrivesAfterAnEditIsDropped() {
        var asked = action(1, "Add Import")
        asked.mayHaveUnsentEdits = true

        var answered = asked
        answered.edits = [CodeActionEdit(range: NSRange(location: 0, length: 0), newText: "import X\n")]

        let applied = CodeNSTextView.actionToApply(
            asked: asked,
            finished: answered,
            textWhenAsked: "let a = 1",
            textNow: "let ab = 1"
        )

        #expect(applied.edits.isEmpty)
    }

    @Test func anAnswerToAnUnchangedDocumentIsUsed() {
        var asked = action(1, "Add Import")
        asked.mayHaveUnsentEdits = true

        var answered = asked
        answered.edits = [CodeActionEdit(range: NSRange(location: 0, length: 0), newText: "import X\n")]

        let applied = CodeNSTextView.actionToApply(
            asked: asked,
            finished: answered,
            textWhenAsked: "let a = 1",
            textNow: "let a = 1"
        )

        #expect(applied.edits.count == 1)
    }

    @Test func noAnswerLeavesTheRowAsItStands() {
        let asked = action(1, "Add Import")

        #expect(CodeNSTextView.actionToApply(
            asked: asked,
            finished: nil,
            textWhenAsked: "x",
            textNow: "x"
        ) == asked)
    }
}
