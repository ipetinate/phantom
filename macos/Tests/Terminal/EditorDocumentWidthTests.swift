import AppKit
@testable import Ghostty
import Testing

/// How wide the document view is, with wrapping off.
///
/// The reason this is computed at all rather than left to AppKit: a
/// horizontally resizable text view is supposed to stay as wide as its widest
/// laid-out line, and in a headless probe of this exact recipe it does for one
/// file and does not for another. One 300-character line in a 400-line file
/// gave a 2233pt frame; the same line in a 5 000-line file left the frame at
/// the viewport's 800pt while the layout manager already reported 2230 used —
/// and a scroll view will not scroll to somewhere its document does not reach,
/// so the tail of that line could not be brought on screen at all.
/// `sizeToFit()` left it at 800 too.
///
/// So the used width decides, and these assert the arithmetic that turns it
/// into a frame.
@MainActor
struct EditorDocumentWidthTests {
    @Test func theDocumentIsAsWideAsTheTextInIt() {
        let width = CodeNSTextView.documentWidth(
            used: 2_230,
            inset: 4,
            viewport: 800
        )
        #expect(width == CGFloat(2_238))
    }

    /// Which is the whole point: past the viewport there is travel for the
    /// scroller, and that travel is what the reader was missing.
    @Test func aLineWiderThanTheViewportLeavesSomethingToScroll() {
        let width = CodeNSTextView.documentWidth(
            used: 2_230,
            inset: 4,
            viewport: 800
        )
        #expect(width - 800 == CGFloat(1_438))
    }

    /// A file of short lines: the document would be 46pt wide, and a document
    /// narrower than its own pane leaves a strip that answers no clicks.
    @Test func aFileOfShortLinesStillFillsThePane() {
        let width = CodeNSTextView.documentWidth(
            used: 46,
            inset: 4,
            viewport: 800
        )
        #expect(width == CGFloat(800))
    }

    /// The inset is counted on both sides, so the last glyph of the longest
    /// line is never flush against the edge of the document.
    @Test func theInsetIsCountedOnBothSides() {
        let width = CodeNSTextView.documentWidth(
            used: 800,
            inset: 4,
            viewport: 800
        )
        #expect(width == CGFloat(808))
    }

    /// The band lives on the same measurement, and this is the case that made
    /// it visible: the band is measured inside `didChangeText`, and AppKit
    /// resizes the document view in the layout pass *after* the edit. Typing
    /// twenty characters at the end of the longest line left the document at
    /// 2233pt while the caret had already reached 2377 — a band that stopped
    /// 144pt short of the cursor and fell further behind with every keystroke.
    @Test func theBandReachesACaretPastTheDocumentsWidth() {
        let frame = CodeTextView.Coordinator.bandFrame(
            caret: NSRect(x: 2_377, y: 120, width: 0, height: 15),
            documentWidth: 2_233,
            clipWidth: 800
        )
        #expect(frame.width == CGFloat(2_377))
        #expect(frame.maxX >= CGFloat(2_377))
    }

    /// And the caret does not shrink a band that is already wider than it, so
    /// a cursor in the first column still gets the full line.
    @Test func aCaretInTheFirstColumnDoesNotShrinkTheBand() {
        let frame = CodeTextView.Coordinator.bandFrame(
            caret: NSRect(x: 9, y: 120, width: 0, height: 15),
            documentWidth: 2_233,
            clipWidth: 800
        )
        #expect(frame.width == CGFloat(2_233))
    }
}
