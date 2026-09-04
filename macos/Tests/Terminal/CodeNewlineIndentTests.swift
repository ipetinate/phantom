import Foundation
@testable import Ghostty
import Testing

/// What Return puts on the next line.
///
/// The cases are written as the text somebody has typed, with `|` marking the
/// caret, because that is how the behaviour was described when it was asked
/// for and it is the only way these read at a glance.
struct CodeNewlineIndentTests {
    private func insert(
        _ marked: String,
        indentUnit: String = "  ",
        lists: Bool = false
    ) -> CodeNewlineIndent.Insertion {
        let caret = (marked as NSString).range(of: "|").location
        let line = marked.replacingOccurrences(of: "|", with: "")
        return CodeNewlineIndent.insertion(
            forLine: line,
            caretInLine: caret,
            indentUnit: indentUnit,
            continuesLists: lists
        )
    }

    /// Applies the insertion to the line, so a test states the result instead
    /// of arithmetic over offsets.
    private func applying(
        _ marked: String,
        indentUnit: String = "  ",
        lists: Bool = false
    ) -> String {
        let caret = (marked as NSString).range(of: "|").location
        let line = marked.replacingOccurrences(of: "|", with: "") as NSString
        let insertion = insert(marked, indentUnit: indentUnit, lists: lists)

        let start = caret - insertion.deletingBefore
        let result = NSMutableString(string: line)
        result.replaceCharacters(
            in: NSRange(location: start, length: insertion.deletingBefore),
            with: insertion.text)
        result.insert("|", at: start + insertion.caretOffset)
        return result as String
    }

    // MARK: - Code

    @Test func keepsTheIndentationOfTheLine() {
        #expect(applying("    const x = 1|") == "    const x = 1\n    |")
    }

    @Test func columnZeroStaysAtColumnZero() {
        #expect(applying("const x = 1|") == "const x = 1\n|")
    }

    /// The case from the report: a line that opens a block indents one level.
    @Test func openingABlockIndentsOneLevel() {
        #expect(applying("  return {|") == "  return {\n    |")
    }

    /// And the case auto-closing actually produces, since typing `{` leaves
    /// `{}` with the caret between them. The closer has to end up on its own
    /// line at the *outer* indentation.
    @Test func aClosedPairBecomesThreeLines() {
        #expect(applying("  return {|}") == "  return {\n    |\n  }")
    }

    @Test(arguments: ["{", "[", "("])
    func everyOpenerCounts(opener: String) {
        #expect(applying("  x = \(opener)|").hasSuffix("\n    |"))
    }

    /// A closer that is not the opener's own is left where it is.
    @Test func aMismatchedCloserIsNotMoved() {
        #expect(applying("  f(|]") == "  f(\n    |]")
    }

    @Test func tabsAreCarriedAsTabs() {
        #expect(applying("\t\tvalue|", indentUnit: "\t") == "\t\tvalue\n\t\t|")
    }

    /// The caret inside the indentation takes only what is behind it, which is
    /// what makes Return at the start of an indented line produce a blank line
    /// rather than a doubly-indented one.
    @Test func onlyTheIndentationBehindTheCaretIsCopied() {
        #expect(applying("  |  deep") == "  \n  |  deep")
    }

    // MARK: - Tags

    /// The same caret marker, with the closing tag the scanner decided on
    /// handed in: unlike a `}`, it is not in the document yet, so the
    /// insertion has to carry it.
    private func applyingTag(
        _ marked: String,
        closingTag: String,
        indentUnit: String = "  "
    ) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let line = marked.replacingOccurrences(of: "|", with: "") as NSString
        guard let insertion = CodeNewlineIndent.tagInsertion(
            forLine: line as String,
            caretInLine: caret,
            indentUnit: indentUnit,
            closingTag: closingTag
        ) else { return nil }

        let result = NSMutableString(string: line)
        result.insert(insertion.text, at: caret)
        result.insert("|", at: caret + insertion.caretOffset)
        return result as String
    }

    @Test func aClosedTagBecomesThreeLines() {
        #expect(applyingTag("  <div>|", closingTag: "</div>") == "  <div>\n    |\n  </div>")
    }

    @Test func theClosingTagLandsAtTheOpeningTagsIndentation() {
        #expect(applyingTag("<ul>|", closingTag: "</ul>") == "<ul>\n  |\n</ul>")
        #expect(
            applyingTag("\t\t<li>|", closingTag: "</li>", indentUnit: "\t")
                == "\t\t<li>\n\t\t\t|\n\t\t</li>")
    }

    /// Whitespace after the caret is the end of the line by any reading, so
    /// the expansion still applies.
    @Test func trailingWhitespaceDoesNotStopTheExpansion() {
        #expect(applyingTag("  <div>|  ", closingTag: "</div>") == "  <div>\n    |\n  </div>  ")
    }

    /// Text after the caret does stop it: expanding would push that text past
    /// the closing tag, into a line and an element it does not belong to.
    @Test func textAfterTheCaretDeclinesTheExpansion() {
        #expect(applyingTag("<p>|already here", closingTag: "</p>") == nil)
        #expect(applyingTag("<p>|</p>", closingTag: "</p>") == nil)
    }

    // MARK: - Markdown lists

    @Test func continuesABullet() {
        #expect(applying("- Header|", lists: true) == "- Header\n- |")
    }

    /// The nesting from the report: two spaces of indent are kept.
    @Test func continuesANestedBullet() {
        #expect(applying("  - Item 2|", lists: true) == "  - Item 2\n  - |")
    }

    @Test(arguments: ["-", "*", "+", ">"])
    func everyBulletCharacter(marker: String) {
        #expect(applying("\(marker) text|", lists: true) == "\(marker) text\n\(marker) |")
    }

    @Test func ordersCountOn() {
        #expect(applying("1. first|", lists: true) == "1. first\n2. |")
        #expect(applying("  9) ninth|", lists: true) == "  9) ninth\n  10) |")
    }

    /// A task list continues unticked: the next thing to do is not done.
    @Test func aTaskListComesBackEmpty() {
        #expect(applying("- [x] done|", lists: true) == "- [x] done\n- [ ] |")
        #expect(applying("- [ ] todo|", lists: true) == "- [ ] todo\n- [ ] |")
    }

    /// Return on an empty item ends the list instead of growing it — the
    /// behaviour that makes a list finishable without reaching for Backspace.
    @Test func anEmptyItemEndsTheList() {
        #expect(applying("  - |", lists: true) == "\n|")
        #expect(applying("1. |", lists: true) == "\n|")
    }

    @Test func theMarkerIsKeptWhenTheCaretIsMidItem() {
        #expect(applying("- head|tail", lists: true) == "- head\n- |tail")
    }

    // MARK: - The line that only looks like a list

    /// Without the space these are not lists, and reading them as one would
    /// insert a marker into ordinary prose.
    @Test(arguments: ["-word|", "1.5|", "*emphasis*|"])
    func aMarkerNeedsItsSpace(line: String) {
        let result = applying(line, lists: true)
        #expect(!result.contains("\n- "), "\(result)")
        #expect(!result.contains("\n2."), "\(result)")
    }

    /// In a language whose lists do not continue, the same line indents like
    /// code — which is the point of the flag.
    @Test func listsDoNotContinueWhereTheyAreNotAThing() {
        #expect(applying("  - not a list|", lists: false) == "  - not a list\n  |")
    }

    @Test func emptyLine() {
        #expect(applying("|", lists: true) == "\n|")
    }
}
