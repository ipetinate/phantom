import AppKit
@testable import Ghostty
import Testing

/// The behaviours a reader can switch off, honoured where they are consumed.
///
/// `EditorFeatureSettingsTests` holds the reading and writing of the switches
/// themselves; this holds what the editor does about them.
///
/// Nothing here touches `UserDefaults`, and that is the point of the shape
/// the engine is in: the switches reach it as an `EditorAssistance` value the
/// host hands over, so a test states the answer it wants instead of writing
/// it into the machine's preferences and hoping no other test is reading them
/// at the same time.
@MainActor
struct EditorFeatureGatingTests {
    /// Concrete colours, not `CodeTheme.fallback`: that one's are dynamic
    /// catalog colours with no components to compare outside a drawing
    /// context — the reason `CodeHighlightAttributeTests` builds its own.
    private let theme = CodeTheme(
        foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
        background: NSColor(calibratedWhite: 0.1, alpha: 1),
        tokens: [:],
        lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
        currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
        currentLineBackground: nil
    )

    private let severity = NSColor(calibratedRed: 1, green: 0.25, blue: 0.2, alpha: 1)

    // MARK: Underlining problems

    private func editor(
        _ assistance: EditorAssistance = .all
    ) -> (CodeTextView.Coordinator, CodeNSTextView) {
        let textView = CodeNSTextView()
        textView.string = "let a = 1\nlet b = 2\n"
        let coordinator = CodeTextView.Coordinator(
            storage: CodeTextStorage(language: .swift, theme: theme, configuration: .default),
            onEdit: { _ in }
        )
        coordinator.textView = textView
        coordinator.apply(assistance: assistance, revision: 1)
        return (coordinator, textView)
    }

    /// One diagnostic to draw. It carries the message as well as the colour,
    /// because both the wave and the hover card are read out of the one text
    /// attribute it becomes — see ``CodeDiagnosticMark``.
    private func problem() -> [(range: NSRange, mark: CodeDiagnosticMark)] {
        [(
            range: NSRange(location: 4, length: 1),
            mark: CodeDiagnosticMark(message: "cannot find type", source: "ts", color: severity)
        )]
    }

    /// The mark that lands is this editor's own key and **not**
    /// `.underlineStyle`. That is the whole of the change from a straight
    /// rule to a wave: AppKit has no wavy underline, so nothing AppKit draws
    /// may be set here.
    @Test func aProblemIsMarkedWithTheDiagnosticKeyAndNotAnUnderline() {
        let (coordinator, textView) = editor()
        coordinator.applyUnderlines(problem())

        let storage = textView.textStorage
        let mark = storage?.attribute(.codeDiagnosticUnderline, at: 4, effectiveRange: nil)
        #expect((mark as? CodeDiagnosticMark)?.color == severity)
        #expect(storage?.attribute(.underlineStyle, at: 4, effectiveRange: nil) == nil)
    }

    /// And only over the characters the problem covers. The reported
    /// complaint was a line-wide rule; a mark that spread past its range
    /// would be the same complaint in a new shape.
    @Test func theMarkCoversOnlyTheProblemsOwnCharacters() {
        let (coordinator, textView) = editor()
        coordinator.applyUnderlines(problem())

        let storage = textView.textStorage
        #expect(storage?.attribute(.codeDiagnosticUnderline, at: 3, effectiveRange: nil) == nil)
        #expect(storage?.attribute(.codeDiagnosticUnderline, at: 5, effectiveRange: nil) == nil)
    }

    @Test func withUnderliningOffNothingIsMarked() {
        var off = EditorAssistance.all
        off.inlineDiagnostics = false

        let (coordinator, textView) = editor(off)
        coordinator.applyUnderlines(problem())

        #expect(textView.textStorage?.attribute(
            .codeDiagnosticUnderline, at: 4, effectiveRange: nil) == nil)
    }

    /// Read live, which is what the setting has to be: the settings window is
    /// open at the same time as the file, and a switch that only takes effect
    /// when the file is reopened reads as a switch that does not work.
    @Test func turningUnderliningOffClearsWhatIsAlreadyThere() {
        let (coordinator, textView) = editor()
        coordinator.applyUnderlines(problem())
        #expect(textView.textStorage?.attribute(
            .codeDiagnosticUnderline, at: 4, effectiveRange: nil) != nil)

        var off = EditorAssistance.all
        off.inlineDiagnostics = false
        coordinator.apply(assistance: off, revision: 2)

        #expect(textView.textStorage?.attribute(
            .codeDiagnosticUnderline, at: 4, effectiveRange: nil) == nil)
    }

    /// And back again, without the host having to send the diagnostics a
    /// second time — the language server has not said anything new, so
    /// nothing is going to.
    @Test func turningUnderliningBackOnRestoresTheMark() {
        let (coordinator, textView) = editor()
        coordinator.applyUnderlines(problem())

        var off = EditorAssistance.all
        off.inlineDiagnostics = false
        coordinator.apply(assistance: off, revision: 2)
        coordinator.apply(assistance: .all, revision: 3)

        let mark = textView.textStorage?.attribute(
            .codeDiagnosticUnderline, at: 4, effectiveRange: nil)
        #expect((mark as? CodeDiagnosticMark)?.color == severity)
    }

    /// The revision is what makes this cheap. An update that changes nothing
    /// must not re-mark the document, or every keystroke would pay for a
    /// switch nobody moved.
    @Test func anUpdateCarryingTheSameRevisionChangesNothing() {
        var off = EditorAssistance.all
        off.inlineDiagnostics = false

        let (coordinator, textView) = editor()
        coordinator.applyUnderlines(problem())
        coordinator.apply(assistance: off, revision: 1)

        #expect(coordinator.assistance.inlineDiagnostics)
        #expect(textView.textStorage?.attribute(
            .codeDiagnosticUnderline, at: 4, effectiveRange: nil) != nil)
    }

    /// A recolour must not take the mark with it. The severity lives in the
    /// colour, so losing it makes a warning and an error identical — the
    /// finding `CodeHighlightAttributeTests` records, carried over to the key
    /// that replaced the underline.
    @Test func aRecolourPutsTheDiagnosticMarkBack() {
        let (coordinator, textView) = editor()
        coordinator.applyUnderlines(problem())

        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }
        coordinator.storage.highlight(
            storage, in: NSRange(location: 0, length: storage.length))

        let mark = storage.attribute(.codeDiagnosticUnderline, at: 4, effectiveRange: nil)
        #expect((mark as? CodeDiagnosticMark)?.color == severity)
    }

    // MARK: Auto-import

    /// Off inserts the name and nothing else — including edits a server sent
    /// with the list rather than on resolve. Skipping only the round trip
    /// would let exactly those servers keep writing imports for somebody who
    /// asked them not to.
    @Test func withAutoImportOffOnlyTheNameGoesIn() {
        let item = CodeCompletionItem(
            kind: .function,
            label: "readFile",
            insertText: "readFile",
            additionalEdits: [CodeTextEdit(
                range: NSRange(location: 0, length: 0),
                newText: "import fs\n")]
        )

        let stripped = CodeNSTextView.withoutAdditionalEdits(item)

        #expect(stripped.additionalEdits.isEmpty)
        #expect(stripped.insertText == "readFile")
        #expect(stripped.label == "readFile")
    }

    /// A row with nothing extra on it comes back untouched rather than
    /// rebuilt, so the switch costs nothing on the common path.
    @Test func aRowWithNoExtraEditsIsUnchanged() {
        let item = CodeCompletionItem(kind: .variable, label: "count", insertText: "count")

        #expect(CodeNSTextView.withoutAdditionalEdits(item) == item)
    }

    // MARK: The git lens and the margin ask different questions

    /// The one interaction worth a test of its own. The margin's marks and
    /// the set of lines the reader has changed come off the same comparison,
    /// and only the first is a decoration. Turning the marks off must not
    /// take the second with it, or the ghost text starts naming whoever last
    /// committed a line the reader has since rewritten.
    @Test func hidingTheMarginKeepsTheChangedLinesTheGitLensReads() {
        let base = ["let a = 1", "let b = 2"]
        let current = ["let a = 1", "let b = 3"]

        var hidden = EditorAssistance.all
        hidden.diffMarks = false

        let (coordinator, _) = editor(hidden)

        #expect(!coordinator.assistance.diffMarks)
        #expect(EditorDiffMarks.changedLines(current: current, base: base) == [2])
    }
}
