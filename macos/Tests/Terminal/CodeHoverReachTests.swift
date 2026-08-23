import AppKit
@testable import Ghostty
import Testing

/// What keeps a hover card alive while the reader is reaching for it, and what
/// the card is anchored to in the first place.
///
/// Both halves are pure by design, and the reason is the same one
/// `CodeHoverPanelTests` gives: a card only becomes visible by asking the
/// window server to display it, and from a test host with no running
/// `NSApplication` event loop that call never returns. `CodeHoverPanel.retains`
/// takes visibility as a value and `CodeNSTextView.symbolRange` takes a string,
/// so the two decisions that decide whether the reported bug is fixed can be
/// stated here without a window existing at all.
///
/// The bug: the card was dismissed the moment the pointer moved off the word,
/// so it could not be read to the end, its links could not be clicked and its
/// text could not be selected. A 400ms grace period had already been added and
/// was not enough — a delay only helps a pointer that keeps moving, and the
/// check it ran when the clock expired asked only whether the pointer had
/// already arrived *on the card*.
@MainActor
struct CodeHoverReachTests {
    /// One word on a line, in screen coordinates: y grows upwards.
    private let word = NSRect(x: 100, y: 500, width: 40, height: 16)

    /// The size of a card with a real description in it, clamped by
    /// `CodeHoverPanel.maximumWidth`.
    private let size = NSSize(width: 460, height: 200)

    /// A card placed the way `showHover` places it, so these tests move if the
    /// placement rule ever does. A display large enough that nothing is
    /// clamped, since clamping is `PanelPlacementTests`' subject.
    private func card(prefers edge: PanelPlacement.Edge) -> NSRect {
        NSRect(
            origin: PanelPlacement.origin(
                anchor: word,
                size: size,
                visible: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                prefers: edge
            ),
            size: size
        )
    }

    // MARK: - Reaching for the card

    /// The literal report: moving the pointer along the word being described
    /// closed the card. Every character is a different offset, and each one
    /// scheduled a close that only a pointer already on the card survived —
    /// so a reader still pointing at the symbol lost the card in 400ms.
    @Test func aPointerStillOnTheWordKeepsTheCard() {
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: 135, y: 508),
            symbol: word,
            card: card(prefers: .below),
            isVisible: true
        )
        #expect(held, "the card must survive the pointer moving across the word it describes")
    }

    @Test func aPointerOnTheCardKeepsTheCard() {
        let frame = card(prefers: .below)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: frame.midX, y: frame.midY),
            symbol: word,
            card: frame,
            isVisible: true
        )
        #expect(held)
    }

    /// The crossing itself, and the reason the delay alone could not fix this:
    /// `PanelPlacement.gap` points separate the line from the card, and a
    /// reader who pauses there — which is what reading does — was on neither.
    @Test func aPointerInTheGapKeepsTheCard() {
        let frame = card(prefers: .below)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: word.midX, y: frame.maxY + PanelPlacement.gap / 2),
            symbol: word,
            card: frame,
            isVisible: true
        )
        #expect(held, "the gap between the word and the card is still hovering")
    }

    /// The gap spans both rectangles sideways, because a reach for the middle
    /// of a 460pt card does not travel straight down out of a word 40pt wide.
    @Test func aDiagonalReachAcrossTheGapKeepsTheCard() {
        let frame = card(prefers: .below)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: frame.maxX - 20, y: frame.maxY + PanelPlacement.gap / 2),
            symbol: word,
            card: frame,
            isVisible: true
        )
        #expect(held)
    }

    /// The same crossing for a card that flipped above the line, since the rule
    /// is written from the two rectangles rather than from the chosen edge.
    @Test func aPointerInTheGapAboveTheLineKeepsTheCard() {
        let frame = card(prefers: .above)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: word.midX, y: frame.minY - PanelPlacement.gap / 2),
            symbol: word,
            card: frame,
            isVisible: true
        )
        #expect(held)
    }

    // MARK: - And still closing

    /// A card that cannot be dismissed is worse than one that dismisses too
    /// eagerly, so the other half is asserted just as hard: another word on the
    /// same line is not the word this card is about.
    @Test func aPointerFurtherAlongTheSameLineLetsTheCardClose() {
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: 400, y: word.midY),
            symbol: word,
            card: card(prefers: .below),
            isVisible: true
        )
        #expect(!held)
    }

    @Test func aPointerPastTheCardLetsTheCardClose() {
        let frame = card(prefers: .below)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: frame.midX, y: frame.minY - 30),
            symbol: word,
            card: frame,
            isVisible: true
        )
        #expect(!held)
    }

    /// A pointer beside the card is a pointer that left. The gap is only as
    /// tall as `PanelPlacement.gap`, so its generosity sideways cannot leak
    /// into the lines above or below it.
    @Test func aPointerBesideTheCardLetsTheCardClose() {
        let frame = card(prefers: .below)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: frame.maxX + 40, y: frame.midY),
            symbol: word,
            card: frame,
            isVisible: true
        )
        #expect(!held)
    }

    /// Regresses dropping the visibility half: a dismissed card keeps the frame
    /// it was last shown at, and a cursor left sitting there must not hold a
    /// card that is not on screen.
    @Test func aCardThatIsNotShowingHoldsNothing() {
        let frame = card(prefers: .below)
        let held = CodeHoverPanel.retains(
            point: NSPoint(x: frame.midX, y: frame.midY),
            symbol: word,
            card: frame,
            isVisible: false
        )
        #expect(!held)
    }

    /// With no room anywhere the placement clamps the card over the line it
    /// describes, and then there is no gap to cross. A null rectangle contains
    /// no point, which is what keeps the answer honest instead of accidentally
    /// generous.
    @Test func thereIsNoGapWhenTheCardMeetsTheWord() {
        let overlapping = NSRect(x: 100, y: 490, width: 460, height: 40)
        let gap = CodeHoverPanel.crossing(from: word, to: overlapping)
        #expect(gap.isNull)
        #expect(!gap.contains(NSPoint(x: word.midX, y: word.midY)))
    }

    // MARK: - What the card is anchored to

    /// Anchoring to the one character under the pointer moved the card
    /// sideways by a glyph on every move within the same symbol, and
    /// re-presenting a card is what pulls it out from under a pointer already
    /// resting on it. The anchor is the whole word, reached from wherever
    /// inside it the pointer landed.
    @Test func theAnchorIsTheWholeWordAroundThePointer() {
        let content = "let value = 1" as NSString
        let range = CodeNSTextView.symbolRange(in: content, containing: 6)
        #expect(content.substring(with: range) == "value")
    }

    @Test func theAnchorReachesTheWordFromItsFirstCharacter() {
        let content = "let value = 1" as NSString
        let range = CodeNSTextView.symbolRange(in: content, containing: 4)
        #expect(content.substring(with: range) == "value")
    }

    /// `$` is part of a JavaScript name, the same rule `identifierRange`
    /// applies to a completion prefix — both now read it from one place, so a
    /// card cannot open against half a name.
    @Test func theAnchorKeepsADollarSignedName() {
        let content = "const $el = 1" as NSString
        let range = CodeNSTextView.symbolRange(in: content, containing: 7)
        #expect(content.substring(with: range) == "$el")
    }

    /// One character for an operator, which is the honest anchor for a hover
    /// over something that is not a name — servers do answer for those.
    @Test func theAnchorIsOneCharacterOnAnOperator() {
        let content = "a + b" as NSString
        let range = CodeNSTextView.symbolRange(in: content, containing: 2)
        #expect(range == NSRange(location: 2, length: 1))
    }

    /// An offset past the end is clamped rather than trapped: the pointer can
    /// be beyond the last glyph of a line, and `characterIndexForInsertion`
    /// answers the end of the document for it.
    @Test func anOffsetPastTheEndIsClamped() {
        let content = "let" as NSString
        let range = CodeNSTextView.symbolRange(in: content, containing: 99)
        #expect(content.substring(with: range) == "let")
    }

    @Test func anEmptyDocumentHasNoAnchor() {
        let range = CodeNSTextView.symbolRange(in: "" as NSString, containing: 0)
        #expect(range.length == 0)
    }
}
