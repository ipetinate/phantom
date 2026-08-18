import AppKit
@testable import Ghostty
import Testing

/// The hover card's own behaviour: whether a point counts as "on the card",
/// and what the card does with the text it is given.
///
/// Neither of these ever orders a window onto the screen. `NSWindow.isVisible`
/// only becomes true by actually asking the window server to display
/// something, and doing that from this test host — which has no running
/// `NSApplication` event loop pumping window-server replies — hangs the
/// call forever instead of returning. `CodeHoverPanel.contains(point:in:
/// isVisible:)` and `.label(_:width:)` exist specifically so this file never
/// has to find that out again.
@MainActor
struct CodeHoverPanelTests {
    // MARK: - contains(point:in:isVisible:)

    /// The geometry `mouseExited` relies on to tell "reaching for the card"
    /// apart from "leaving for good".
    @Test func aPointInsideAVisibleFrameIsContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CodeHoverPanel.contains(point: NSPoint(x: 150, y: 150), in: frame, isVisible: true))
    }

    @Test func aPointOutsideTheFrameIsNotContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(!CodeHoverPanel.contains(point: NSPoint(x: 10, y: 10), in: frame, isVisible: true))
    }

    /// Regresses dropping the `isVisible` half of the check: a dismissed
    /// panel still has a frame sitting wherever it was last shown, and a
    /// coincidental cursor position there must not be read as "contained".
    @Test func aPointInsideAnInvisibleFrameIsNotContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(!CodeHoverPanel.contains(point: NSPoint(x: 150, y: 150), in: frame, isVisible: false))
    }

    @Test func aPointExactlyOnTheEdgeIsContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CodeHoverPanel.contains(point: NSPoint(x: 100, y: 100), in: frame, isVisible: true))
    }

    // MARK: - Which side of the line the card opens on

    /// The card opens **below** the line, like the completion list and through
    /// the same `PanelPlacement`. Above put the card between the pointer and
    /// the word it describes, so reaching it meant dragging back across that
    /// word — and across everything else the language server has an opinion
    /// about on the way.
    ///
    /// Asserted as a value rather than by presenting a card: `present` ends in
    /// `orderFront`, which from this host never returns.
    @Test func theCardPrefersToOpenBelowTheLine() {
        #expect(CodeHoverPanel.preferredEdge == .below)
    }

    /// And the preference is one the geometry honours: with room under the
    /// line, the card lands under it and leaves the line itself uncovered.
    @Test func theCardLandsUnderTheLineWhenThereIsRoom() {
        let anchor = NSRect(x: 100, y: 400, width: 60, height: 16)
        let size = NSSize(width: 200, height: 100)

        let origin = PanelPlacement.origin(
            anchor: anchor,
            size: size,
            visible: NSRect(x: 0, y: 0, width: 1000, height: 800),
            prefers: CodeHoverPanel.preferredEdge
        )

        #expect(origin.y == anchor.minY - PanelPlacement.gap - size.height)
        #expect(origin.y + size.height < anchor.minY, "the card must not cover the line it describes")
    }

    /// The flip has to survive the change: a word near the bottom of the
    /// display still gets its card above the line rather than off the screen.
    @Test func theCardStillFlipsAboveWithNoRoomBelow() {
        let anchor = NSRect(x: 100, y: 20, width: 60, height: 16)
        let size = NSSize(width: 200, height: 100)

        let origin = PanelPlacement.origin(
            anchor: anchor,
            size: size,
            visible: NSRect(x: 0, y: 0, width: 1000, height: 800),
            prefers: CodeHoverPanel.preferredEdge
        )

        #expect(origin.y == anchor.maxY + PanelPlacement.gap)
    }

    // MARK: - Presented labels

    /// Regresses two things reported from the same screenshot: a copy
    /// button that had no reason to exist once the text itself could be
    /// selected, and — the actual bug — selecting that text discarding its
    /// syntax colours and shrinking to a different font. A selectable
    /// `NSTextField` still routes clicks through the shared field editor,
    /// and that editor draws from `stringValue` plus the control's own
    /// font/colour unless told otherwise — which is exactly the flat,
    /// recoloured, differently-sized text that appeared the moment a
    /// selection started.
    @Test func aLabelStaysSelectableAndKeepsItsAttributesOnClick() {
        let colored = NSMutableAttributedString(string: "let x", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.systemPurple,
        ])

        let field = CodeHoverPanel.label(colored, width: 200)

        #expect(field.isSelectable, "the card's text must stay selectable so it can be copied by hand")
        #expect(
            field.allowsEditingTextAttributes,
            "without this, clicking into the text for selection drops its syntax colours and font"
        )
        #expect(field.isEditable == false, "selectable is not the same as editable — this is still a label")
    }
}
