import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The bridge between the rendered document and the split beside it.
///
/// `MarkdownRendererTests` already covers the mapping in *characters*; this
/// covers it in **points**, which is the form a scroll link can use and the
/// only form that proves the source lines recorded by the parser survive all
/// the way to something drawn on screen.
@MainActor
struct MarkdownPreviewTests {
    /// A real, never-shown window, following `CodeHoverPersistenceTests`:
    /// enough for TextKit 1 to lay out real glyphs and for the bounding
    /// rects to be true, without putting anything on the developer's actual
    /// display. Nothing here reaches `orderFront`.
    private func laidOut(_ markdown: String) -> (NSWindow, MarkdownPreviewView.Coordinator) {
        let frame = NSRect(x: 0, y: 0, width: 520, height: 400)

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: frame, textContainer: container)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = CGSize(width: 20, height: 20)

        let output = MarkdownRenderer(style: .fallback).render(MarkdownParser.parse(markdown))
        textView.textStorage?.setAttributedString(output.text)
        layoutManager.ensureLayout(for: container)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = textView

        let coordinator = MarkdownPreviewView.Coordinator()
        coordinator.textView = textView
        coordinator.output = output
        return (window, coordinator)
    }

    private var document: String {
        """
        # Title

        A paragraph of prose that says something.

        ```swift
        let x = 1
        ```

        ## Second

        The end.
        """
    }

    // MARK: - Source line to a place on screen

    @Test func theTopBlockRendersAtTheTop() {
        let (window, coordinator) = laidOut(document)
        _ = window
        let top = coordinator.renderedY(forSourceLine: 0)
        #expect(top != nil)
        #expect((top ?? 99) <= 20.5, "the first block should sit at the container inset, got \(top ?? -1)")
    }

    /// The property a synchronised scroll actually depends on: further down
    /// the source is further down the render. Heights differ wildly between
    /// the two panes, so this ordering is the only thing that has to hold.
    @Test func laterSourceLinesRenderFurtherDown() {
        let (window, coordinator) = laidOut(document)
        _ = window

        let positions = [0, 2, 4, 8, 10].compactMap { coordinator.renderedY(forSourceLine: $0) }
        #expect(positions.count == 5)
        for (above, below) in zip(positions, positions.dropFirst()) {
            #expect(below >= above, "expected \(below) to be at or below \(above)")
        }
        #expect((positions.last ?? 0) > (positions.first ?? 0))
    }

    @Test func aSourceLineRoundTripsThroughThePreview() {
        let (window, coordinator) = laidOut(document)
        _ = window

        /// Line 4 opens the fence, whose block covers lines 4...6 — so the
        /// round trip lands on the block's first line, not on the line asked
        /// for. That is the contract: a block is the unit, not a line.
        guard let y = coordinator.renderedY(forSourceLine: 5) else {
            #expect(Bool(false), "no position for the fence")
            return
        }
        #expect(coordinator.sourceLine(forRenderedY: y) == 4)
    }

    @Test func aPointAboveTheFirstBlockAnswersWithTheFirstBlock() {
        let (window, coordinator) = laidOut(document)
        _ = window
        #expect(coordinator.sourceLine(forRenderedY: 0) == 0)
    }

    @Test func anEmptyDocumentAnswersNothingRatherThanCrashing() {
        let (window, coordinator) = laidOut("")
        _ = window
        #expect(coordinator.renderedY(forSourceLine: 0) == nil)
        #expect(coordinator.sourceLine(forRenderedY: 40) == nil)
    }

    // MARK: - Decoration must not strangle the text it decorates

    /// How many line fragments a stretch of text was broken into, and how
    /// wide the widest one came out.
    private func fragments(
        of probe: String,
        in coordinator: MarkdownPreviewView.Coordinator
    ) -> (count: Int, widest: CGFloat)? {
        guard let textView = coordinator.textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return nil }

        let range = (textView.string as NSString).range(of: probe)
        guard range.location != NSNotFound else { return nil }

        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var count = 0
        var widest: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            count += 1
            widest = max(widest, used.width)
        }
        _ = container
        return (count, widest)
    }

    /// ⚠️ The bug this suite exists to never allow again.
    ///
    /// Headings, quotes, fenced code and tables rendered **one character per
    /// line** — a vertical column of letters — while the paragraph between
    /// them was perfect. The cause was `NSTextBlock` defaulting its content
    /// width to zero, so every decorated block had about ten points to lay
    /// out in.
    ///
    /// Asserted in *line fragments* because that is the exact shape of the
    /// failure: a short heading that needs one line and got eleven. Position
    /// and ordering — what the rest of this suite checks — stayed perfectly
    /// correct throughout the bug, which is why none of those tests caught
    /// it.
    @Test func everyDecoratedBlockLaysOutOnOneLine() {
        let everything = """
        # Diff Fixture

        A small repository for exercising the preview.

        ## What is here

        > A quote that is long enough to be worth wrapping.

        ```swift
        let phantom = Terminal()
        ```

        | Setting | Default |
        |---------|--------:|
        | Theme   | system  |
        """

        let (window, coordinator) = laidOut(everything)
        _ = window

        let probes = [
            "Diff Fixture",
            "A small repository for exercising",
            "What is here",
            "A quote that is long enough",
            "let phantom = Terminal()",
            "Setting",
            "system",
        ]

        for probe in probes {
            guard let measured = fragments(of: probe, in: coordinator) else {
                #expect(Bool(false), "could not find \(probe) in the rendered text")
                continue
            }
            #expect(
                measured.count == 1,
                "\(probe) was broken into \(measured.count) lines at \(measured.widest)pt wide"
            )
        }
    }

    /// The narrowest statement of the same fault, kept separate because it
    /// is the one that reads as an assertion about *width* rather than about
    /// wrapping: a decorated block must get roughly the room a plain
    /// paragraph gets, not ten points.
    @Test func aHeadingGetsTheSameRoomAsAParagraph() {
        let (window, coordinator) = laidOut(
            "# A heading long enough that it would surely wrap if starved\n\n"
                + "A paragraph long enough that it would surely wrap if starved."
        )
        _ = window

        guard let heading = fragments(of: "A heading long enough", in: coordinator),
              let paragraph = fragments(of: "A paragraph long enough", in: coordinator)
        else {
            #expect(Bool(false), "probes not found")
            return
        }
        #expect(heading.widest > paragraph.widest / 2)
    }

    // MARK: - The handle the host holds

    @Test func anchorsWithNoPreviewAnswerNothing() {
        let anchors = MarkdownPreviewAnchors()
        #expect(!anchors.isReady)
        #expect(anchors.renderedY(forSourceLine: 0) == nil)
        #expect(anchors.sourceLine(forRenderedY: 0) == nil)
    }

    @Test func anchorsAnswerOnceAPreviewIsAttached() {
        let (window, coordinator) = laidOut(document)
        _ = window

        let anchors = MarkdownPreviewAnchors()
        anchors.serve(coordinator)

        #expect(anchors.isReady)
        #expect(anchors.renderedY(forSourceLine: 0) == coordinator.renderedY(forSourceLine: 0))
        #expect(anchors.sourceLine(forRenderedY: 0) == 0)
    }

    /// A preview that goes away must not leave the host holding a handle
    /// that still claims to know where things are.
    @Test func anchorsGoQuietWhenThePreviewIsTornDown() {
        let (window, coordinator) = laidOut(document)
        _ = window

        let anchors = MarkdownPreviewAnchors()
        anchors.serve(coordinator)
        #expect(anchors.isReady)

        anchors.clear()
        #expect(!anchors.isReady)
        #expect(anchors.renderedY(forSourceLine: 0) == nil)
    }
}
