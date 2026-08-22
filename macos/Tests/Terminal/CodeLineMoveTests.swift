import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Moving a line up and down.
///
/// Written as the text somebody is looking at, with `|` marking the caret — or
/// a pair of them marking a selection — because every interesting case here is
/// about *which* lines moved, and offsets do not read at a glance.
struct CodeLineMoveTests {
    private func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let parts = marked.components(separatedBy: "|")
        let location = (parts[0] as NSString).length
        let length = parts.count > 2 ? (parts[1] as NSString).length : 0
        return (parts.joined(), NSRange(location: location, length: length))
    }

    /// Applies the move and puts the markers back, so a test states the text it
    /// expects rather than arithmetic over ranges.
    private func applying(_ marked: String, _ direction: CodeLineMove.Direction) -> String? {
        let (text, selection) = parse(marked)
        guard let move = CodeLineMove.move(
            in: text as NSString, selection: selection, direction: direction)
        else { return nil }

        let result = NSMutableString(string: text)
        result.replaceCharacters(in: move.replacement, with: move.text)

        /// The far marker first: inserting the near one would shift it.
        if move.selection.length > 0 {
            result.insert("|", at: NSMaxRange(move.selection))
        }
        result.insert("|", at: move.selection.location)
        return result as String
    }

    // MARK: - The ordinary case

    @Test func aLineTradesPlacesWithTheOneAbove() {
        #expect(applying("a\n|b\nc", .up) == "|b\na\nc")
    }

    @Test func aLineTradesPlacesWithTheOneBelow() {
        #expect(applying("a\n|b\nc", .down) == "a\nc\n|b")
    }

    /// The caret keeps its column, so holding the shortcut walks one line
    /// through a file instead of drifting to column zero.
    @Test func theCaretTravelsWithTheLineItIsOn() {
        #expect(applying("aaa\nb|bb\nccc", .up) == "b|bb\naaa\nccc")
    }

    // MARK: - Boundaries

    @Test func theFirstLineHasNowhereToGoUp() {
        #expect(applying("|a\nb", .up) == nil)
    }

    @Test func theLastLineOfAFileWithNoFinalNewlineHasNowhereToGoDown() {
        #expect(applying("a\n|b", .down) == nil)
    }

    /// Almost every file ends in a newline, which leaves a blank last line the
    /// reader can see — so the last line of text can still move down, onto it.
    /// A first attempt returned nil here and the command looked broken on the
    /// commonest file there is.
    @Test func theLastLineCanMoveOntoTheBlankLineATrailingNewlineLeaves() {
        #expect(applying("a\n|b\n", .down) == "a\n\n|b")
    }

    @Test func theBlankLastLineItselfHasNowhereToGoDown() {
        #expect(applying("a\nb\n|", .down) == nil)
    }

    @Test func theBlankLastLineCanMoveUp() {
        #expect(applying("a\nb\n|", .up) == "a\n|\nb")
    }

    /// The line that ends up last inherits having no terminator, which is what
    /// keeps the file the same length and the same shape. Getting this wrong
    /// either duplicates a newline or eats one.
    @Test func aFileWithNoFinalNewlineKeepsNotHavingOne() {
        #expect(applying("a\n|b", .up) == "|b\na")

        let (text, selection) = parse("a\n|b")
        let move = CodeLineMove.move(in: text as NSString, selection: selection, direction: .up)
        #expect(move?.text.utf16.count == move?.replacement.length)
    }

    @Test func windowsLineEndingsSurvive() {
        #expect(applying("a\r\n|b\r\nc", .up) == "|b\r\na\r\nc")
    }

    // MARK: - A selected block

    @Test func everyLineTheSelectionTouchesMovesTogether() {
        #expect(applying("|a\nb|\nc", .down) == "c\n|a\nb|")
    }

    /// A selection that stops at the start of the next line has not touched
    /// that line — it stopped on the terminator of the one before. Without
    /// this, selecting one whole line by dragging into the line below moved
    /// two of them.
    @Test func aSelectionEndingAtALineStartDoesNotDragThatLineAlong() {
        #expect(applying("|a\n|b\nc", .down) == "b\n|a\n|c")
    }

    @Test func theSelectionStaysOnTheTextItWasOn() throws {
        let (text, selection) = parse("x\n|a\nb|\nc")
        let move = try #require(
            CodeLineMove.move(in: text as NSString, selection: selection, direction: .up))

        let moved = NSMutableString(string: text)
        moved.replaceCharacters(in: move.replacement, with: move.text)
        #expect(moved.substring(with: move.selection) == "a\nb")
    }

    // MARK: - What it must not do

    /// Moving a line is not formatting it. A version that reindented on the
    /// way would rewrite lines the reader only meant to reorder.
    @Test func indentationIsCarriedVerbatim() {
        #expect(applying("    a = 1\n  |b = 2", .up) == "  |b = 2\n    a = 1")
    }

    @Test func theEditIsExactlyAsLongAsWhatItReplaces() {
        for marked in ["a\n|b\nc", "a\n|b\n", "  a\n\tb|", "a\r\n|b\r\nc", "a\nb\n|"] {
            let (text, selection) = parse(marked)
            for direction in [CodeLineMove.Direction.up, .down] {
                guard let move = CodeLineMove.move(
                    in: text as NSString, selection: selection, direction: direction)
                else { continue }
                #expect(
                    move.text.utf16.count == move.replacement.length,
                    "\(marked) \(direction) changed the length of the file")
            }
        }
    }

    /// The whole trailing-newline case rests on what `NSString` calls the line
    /// at the very end of a terminated file, and that is a framework promise
    /// this code reads rather than makes. Pinned, so a future OS that answers
    /// differently fails here instead of in the editor.
    @Test func theRangePastAFinalNewlineIsAnEmptyLineOfItsOwn() {
        let text = "a\nb\n" as NSString
        #expect(text.lineRange(for: NSRange(location: 4, length: 0)) == NSRange(location: 4, length: 0))
        #expect(("a\nb" as NSString).lineRange(for: NSRange(location: 3, length: 0))
            == NSRange(location: 2, length: 1))
    }
}

/// The command as the app declares it, and as the reader sees it.
struct MoveLineDeclarationTests {
    @Test func bothDirectionsShipOnShiftOptionArrows() {
        #expect(PhantomShortcutMap.defaults.shortcuts(for: .moveLineUp)
            == [PhantomShortcut(key: PhantomShortcut.upArrow, modifiers: [.shift, .option])])
        #expect(PhantomShortcutMap.defaults.shortcuts(for: .moveLineDown)
            == [PhantomShortcut(key: PhantomShortcut.downArrow, modifiers: [.shift, .option])])
    }

    @Test func theyBelongToTheEditorSoTheTerminalKeepsTheKeysElsewhere() {
        let editor = PhantomShortcutAction.actions(in: .editor)
        #expect(editor.contains(.moveLineUp))
        #expect(editor.contains(.moveLineDown))
    }

    /// The settings row would otherwise show the private-use character the
    /// arrow key reports, which draws as an empty box.
    @Test func anArrowIsSpelledAsAnArrow() {
        let up = PhantomShortcut(key: PhantomShortcut.upArrow, modifiers: [.shift, .option])
        #expect(up.displayString == "⌥⇧↑")

        let down = PhantomShortcut(key: PhantomShortcut.downArrow, modifiers: [.shift, .option])
        #expect(down.displayString == "⌥⇧↓")
    }

    /// The raw value is the storage key and the string that crosses to the
    /// engine, so it is pinned: renaming a case abandons whatever the reader
    /// configured, in silence.
    @Test func theStorageKeysAreTheOnesTheEngineAnswersTo() {
        #expect(PhantomShortcutAction.moveLineUp.rawValue == "moveLineUp")
        #expect(PhantomShortcutAction.moveLineDown.rawValue == "moveLineDown")
    }

    /// An arrow survives the round trip through defaults. The key is a
    /// private-use scalar, and the serialization takes the key by position
    /// after the last separator — so this is really asking whether that still
    /// holds for a character nobody types.
    @Test func anArrowBindingSurvivesBeingWrittenDownAndReadBack() throws {
        let original = PhantomShortcut(key: PhantomShortcut.upArrow, modifiers: [.shift, .option])
        let restored = try #require(PhantomShortcut(serialized: original.serialized))
        #expect(restored == original)
    }
}

/// The keys, on a real text view with no window in sight.
@MainActor
struct MoveLineKeyTests {
    private func event(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    private func textView(_ text: String, caret: Int) -> CodeNSTextView {
        let textView = CodeNSTextView()
        textView.allowsUndo = true
        textView.string = text
        textView.commandShortcuts = [
            "moveLineUp": [EditorShortcut(key: PhantomShortcut.upArrow, modifiers: [.shift, .option])],
            "moveLineDown": [
                EditorShortcut(key: PhantomShortcut.downArrow, modifiers: [.shift, .option]),
            ],
        ]
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return EditorFocus.give(to: textView)
    }

    /// An arrow event carries the function-key bit, and on many keyboards the
    /// numeric-pad bit too. Both are in `deviceIndependentFlagsMask`, which is
    /// what the match used to compare against — so this is the case that used
    /// to fail while the same test with a letter passed.
    @Test func shiftOptionUpMovesTheLineUp() {
        let textView = self.textView("a\nb\nc", caret: 2)
        let up = event(PhantomShortcut.upArrow, [.shift, .option, .function, .numericPad])

        #expect(textView.performKeyEquivalent(with: up))
        #expect(textView.string == "b\na\nc")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func shiftOptionDownMovesTheLineDown() {
        let textView = self.textView("a\nb\nc", caret: 2)
        let down = event(PhantomShortcut.downArrow, [.shift, .option, .function])

        #expect(textView.performKeyEquivalent(with: down))
        #expect(textView.string == "a\nc\nb")
    }

    /// `performKeyEquivalent` is documented in this file as only seeing ⌘
    /// combinations, and whether that is true of ⇧⌥ is AppKit's business, not
    /// ours. So `keyDown` answers too, and this pins that the second path
    /// works on its own — otherwise the command would depend on which claim
    /// about AppKit happens to be right.
    @Test func keyDownMovesTheLineToo() {
        let textView = self.textView("a\nb\nc", caret: 2)
        textView.keyDown(with: event(PhantomShortcut.upArrow, [.shift, .option, .function]))

        #expect(textView.string == "b\na\nc")
    }

    /// A boundary is still ours to swallow: handing ⇧⌥↑ back to AppKit at the
    /// top of a file starts extending the selection by paragraphs, so holding
    /// the shortcut would stop moving lines and start selecting them.
    @Test func theTopOfTheFileSwallowsTheKeyWithoutMovingAnything() {
        let textView = self.textView("a\nb", caret: 0)
        let up = event(PhantomShortcut.upArrow, [.shift, .option, .function])

        #expect(textView.performKeyEquivalent(with: up))
        #expect(textView.string == "a\nb")
    }

    /// Typing must survive the fallback in `keyDown`. A bare key and a shifted
    /// key are how text is entered, so neither may be consulted against the
    /// bindings — a reader who bound one to a command would otherwise end up
    /// with a text view that cannot type the letter.
    ///
    /// Stated as "the lines did not move" rather than "the letter arrived":
    /// whether `insertText` lands without a window is AppKit's business, and
    /// the claim being made here is about what the fallback declines to do.
    @Test func aPlainKeyIsNeverCheckedAgainstTheBindings() {
        let textView = self.textView("a\nb", caret: 2)
        textView.commandShortcuts = ["moveLineUp": [EditorShortcut(key: "q", modifiers: [])]]
        textView.keyDown(with: event("q", []))

        #expect(textView.string.hasPrefix("a\n"))
    }

    @Test func aShiftedKeyIsNeverCheckedAgainstTheBindings() {
        let textView = self.textView("a\nb", caret: 2)
        textView.commandShortcuts = ["moveLineUp": [EditorShortcut(key: "q", modifiers: [.shift])]]
        textView.keyDown(with: event("Q", [.shift]))

        #expect(textView.string.hasPrefix("a\n"))
    }

    /// The move is one edit, so it is one thing to undo. Two edits would make
    /// the reader press ⌘Z twice to put a line back where it was.
    @Test func theWholeMoveIsASingleUndoStep() throws {
        let textView = self.textView("a\nb\nc", caret: 2)
        #expect(textView.performKeyEquivalent(with:
            event(PhantomShortcut.upArrow, [.shift, .option, .function])))
        #expect(textView.string == "b\na\nc")

        let undo = try #require(textView.undoManager)
        undo.undo()
        #expect(textView.string == "a\nb\nc")
    }
}
