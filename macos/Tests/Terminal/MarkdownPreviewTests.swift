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
    private func laidOut(_ markdown: String, baseURL: URL? = nil) -> (NSWindow, MarkdownPreviewView.Coordinator) {
        let frame = NSRect(x: 0, y: 0, width: 520, height: 400)

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        /// The preview's own subclass, because the coordinator holds that type
        /// — it is the view that owns the column arithmetic. Nothing here sets
        /// a measure, so it behaves as the plain text view it used to be.
        let textView = MarkdownDocumentTextView(frame: frame, textContainer: container)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = CGSize(width: 20, height: 20)

        let output = MarkdownRenderer(style: .fallback, baseURL: baseURL)
            .render(MarkdownParser.parse(markdown))
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

    // MARK: - The pane has to be able to grow past its viewport

    /// ⚠️ The bug this test exists to never allow again: the preview drew
    /// exactly one screenful and could not be scrolled past it, so every
    /// document longer than the pane was half unreadable.
    ///
    /// Built through `makeTextView` and dropped into a real `NSScrollView`,
    /// because that is the only place the fault was visible. The parse, the
    /// render and the anchor snapshot were all correct throughout — the
    /// *document view* was simply the same height as the clip view, which
    /// leaves the scroller no travel no matter how tall the text is.
    ///
    /// Asserted against the layout manager's own used rect rather than a
    /// fixed number of points, so it keeps holding when the styling changes
    /// what a paragraph costs. No window is involved: the scroll view lays
    /// out offscreen, and nothing here is ever shown.
    @Test func theRenderedDocumentGrowsPastItsViewport() {
        let viewport = NSRect(x: 0, y: 0, width: 480, height: 200)
        let scrollView = NSScrollView(frame: viewport)
        let textView = MarkdownPreviewView.makeTextView()
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()

        let tall = (1...120)
            .map { "Paragraph \($0), long enough that a hundred of them cannot fit on one screen." }
            .joined(separator: "\n\n")
        let output = MarkdownRenderer(style: .fallback).render(MarkdownParser.parse(tall))
        textView.textStorage?.setAttributedString(output.text)

        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            #expect(Bool(false), "the preview lost the TextKit 1 stack its decoration needs")
            return
        }
        layoutManager.ensureLayout(for: container)

        let used = layoutManager.usedRect(for: container).height
        #expect(used > viewport.height * 3, "the fixture is too short to prove anything")
        #expect(
            textView.frame.height >= used,
            """
            the document view came out \(textView.frame.height)pt tall for \(used)pt of text \
            (viewport \(viewport.height)pt) — everything past the first screen is unreachable
            """
        )
    }

    // MARK: - An image has to take up room

    /// ⚠️ That an attachment carries the right attribute is not the same claim
    /// as an image being *drawn*, and only the second one is what the reader
    /// asked for. `MarkdownRendererTests` can assert the attribute without a
    /// window; this measures the laid-out text and fails if the picture cost
    /// nothing, which is what a preview that draws no images looks like from
    /// the outside.
    @Test func aDrawnImageTakesUpItsOwnHeight() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markdown-preview-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = CGSize(width: 200, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.drawSwatch(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        try #require(image.tiffRepresentation).write(to: directory.appendingPathComponent("logo.tiff"))

        let withImage = try height(of: "![logo](./logo.tiff)", baseURL: directory)
        let withoutImage = try height(of: "logo", baseURL: directory)
        #expect(withImage > withoutImage + 60, "the image cost \(withImage - withoutImage)pt of height")
    }

    /// How tall a document lays out, in points.
    private func height(of markdown: String, baseURL: URL?) throws -> CGFloat {
        let (window, coordinator) = laidOut(markdown, baseURL: baseURL)
        _ = window

        let textView = try #require(coordinator.textView)
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
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

    // MARK: - The file's name decides the dialect

    /// The one line that makes an `.mdx` file render as MDX, held down.
    ///
    /// It fails silently when wrong: without the flavor, `import Callout
    /// from './c'` is drawn as an ordinary paragraph and the reader is
    /// given no sign that anything was treated differently. Nothing throws
    /// and the page still looks like a page.
    @Test func anMdxFileIsParsedAsMdx() {
        let source = "import Callout from './c'\n\n# Title\n\n<Callout>hi</Callout>"

        let mdx = MarkdownPreviewView.document(
            text: source,
            fileURL: URL(fileURLWithPath: "/docs/page.mdx")
        )
        #expect(mdx.flavor == .mdx)
        #expect(mdx.blocks.first?.kind == .script("import Callout from './c'"))
    }

    /// The same text in a `.md` file is prose, because in Markdown it is.
    @Test func aMarkdownFileIsNotParsedAsMdx() {
        let source = "import Callout from './c'\n\n# Title"

        let markdown = MarkdownPreviewView.document(
            text: source,
            fileURL: URL(fileURLWithPath: "/docs/README.md")
        )
        #expect(markdown.flavor == .markdown)
        #expect(markdown.blocks.first?.kind == .paragraph(text: "import Callout from './c'"))
    }

    /// An unsaved buffer has no name to read, and plain markdown is the
    /// answer that cannot be wrong in a surprising way.
    @Test func aBufferWithNoFileIsPlainMarkdown() {
        #expect(MarkdownPreviewView.document(text: "# T", fileURL: nil).flavor == .markdown)
    }

    /// End to end through the layout, because the caption is the promise:
    /// an MDX file must *say* that its module and its component were shown
    /// rather than run.
    @Test func anMdxDocumentDrawsItsHonestCaptions() {
        let source = """
        ---
        title: x
        ---

        import Callout from './c'

        # Getting started

        <Callout type="warn">
          Careful.
        </Callout>

        <!-- invisible -->
        """

        let document = MarkdownPreviewView.document(
            text: source,
            fileURL: URL(fileURLWithPath: "/docs/page.mdx")
        )
        let rendered = MarkdownRenderer(style: .fallback).render(document).text.string

        #expect(rendered.contains("front matter"))
        #expect(rendered.contains("module — not evaluated"))
        #expect(rendered.contains("component — shown as source, not rendered"))
        #expect(rendered.contains("import Callout from './c'"))
        #expect(rendered.contains("<Callout type=\"warn\">"))
        #expect(!rendered.contains("invisible"), "an HTML comment must not be drawn")
    }

    // MARK: - The snapshot the host holds

    @Test func anchorsWithNoPreviewAnswerNothing() {
        let anchors = MarkdownPreviewAnchors()
        #expect(!anchors.isReady)
        #expect(anchors.renderedY(forSourceLine: 0) == nil)
        #expect(anchors.sourceLine(forRenderedY: 0) == nil)
    }

    @Test func aLaidOutPreviewProducesAnAnchorPerBlock() {
        let (window, coordinator) = laidOut(document)
        _ = window

        let snapshot = coordinator.scrollAnchors()
        #expect(snapshot.count == coordinator.output?.anchors.count)
        #expect(snapshot.first?.sourceLine == 0)

        /// Ascending in both fields, which is what the lookups below rely on
        /// to be a scan rather than a search.
        for (above, below) in zip(snapshot, snapshot.dropFirst()) {
            #expect(below.sourceLine > above.sourceLine)
            #expect(below.renderedY >= above.renderedY)
        }
    }

    @Test func anchorsAnswerBothDirectionsOnceFilled() {
        let (window, coordinator) = laidOut(document)
        _ = window

        let anchors = MarkdownPreviewAnchors()
        anchors.update(to: coordinator.scrollAnchors(), sourceLineCount: 11)
        #expect(anchors.isReady)

        /// Line 5 is inside the fence, whose block starts at line 4 — so it
        /// answers with where the *block* was drawn, and the reverse lands
        /// back on the block's first line.
        guard let y = anchors.renderedY(forSourceLine: 5) else {
            #expect(Bool(false), "no position for the fence")
            return
        }
        #expect(anchors.sourceLine(forRenderedY: y) == 4)
        #expect(anchors.renderedY(forSourceLine: 0) == anchors.anchors.first?.renderedY)
    }

    /// A preview that goes away must not leave the host holding a snapshot
    /// that still claims to know where things are.
    @Test func anchorsGoQuietWhenThePreviewIsTornDown() {
        let (window, coordinator) = laidOut(document)
        _ = window

        let anchors = MarkdownPreviewAnchors()
        anchors.update(to: coordinator.scrollAnchors(), sourceLineCount: 11)
        #expect(anchors.isReady)

        anchors.clear()
        #expect(!anchors.isReady)
        #expect(anchors.renderedY(forSourceLine: 0) == nil)
    }

    // MARK: - The scroll strategy, which is why any of this was recorded

    /// Pure arithmetic over the snapshot, so the two directions can be
    /// checked without a scroll view, a window or a run loop.
    /// Viewports are kept well under both content lengths on purpose: a
    /// follower shorter than its own viewport has no travel, so
    /// `followerOffset` clamps every answer to zero and the test passes or
    /// fails for a reason that has nothing to do with the mapping.
    private func geometry(
        leaderOffset: CGFloat,
        leaderContent: CGFloat,
        followerContent: CGFloat,
        viewport: CGFloat = 100
    ) -> ScrollSyncGeometry {
        ScrollSyncGeometry(
            leaderOffset: leaderOffset,
            leaderContentLength: leaderContent,
            leaderViewportLength: viewport,
            followerContentLength: followerContent,
            followerViewportLength: viewport
        )
    }

    private func filledAnchors() -> MarkdownPreviewAnchors {
        let anchors = MarkdownPreviewAnchors()
        anchors.update(
            to: [
                MarkdownScrollAnchor(sourceLine: 0, renderedY: 0),
                MarkdownScrollAnchor(sourceLine: 10, renderedY: 500),
                MarkdownScrollAnchor(sourceLine: 20, renderedY: 600),
            ],
            sourceLineCount: 30
        )
        return anchors
    }

    /// Source leading: a raw offset becomes a line, and the line becomes the
    /// place the preview drew it. The heights are deliberately unrelated —
    /// 300pt of source against 1000pt of preview — because that is the case
    /// proportion gets wrong.
    @Test func theSourceLeadingLandsThePreviewOnTheRightBlock() {
        let strategy = ScrollSyncStrategy.markdownPreview(filledAnchors(), previewSide: .second)

        /// 300pt over 30 lines is 10pt a line, so 100pt in is line 10, whose
        /// block was drawn at 500.
        let offset = strategy.followerOffset(
            for: geometry(leaderOffset: 100, leaderContent: 300, followerContent: 1000),
            from: .first
        )
        #expect(offset == 500)
    }

    /// The preview leading composes the other way, and must not reuse the
    /// map above — that is the whole reason the strategy is told the side.
    @Test func thePreviewLeadingLandsTheSourceOnTheRightLine() {
        let strategy = ScrollSyncStrategy.markdownPreview(filledAnchors(), previewSide: .second)

        /// 520pt into the preview is inside the block that began at line 10;
        /// 10 lines at 10pt each is 100pt down the source.
        let offset = strategy.followerOffset(
            for: geometry(leaderOffset: 520, leaderContent: 1000, followerContent: 300),
            from: .second
        )
        #expect(offset == 100)
    }

    /// A strategy that ignored the side would give the same answer for both
    /// directions at the same offset. This is the regression that catches a
    /// symmetric mapping sneaking back in.
    @Test func theTwoDirectionsAreNotTheSameFunction() {
        let strategy = ScrollSyncStrategy.markdownPreview(filledAnchors(), previewSide: .second)
        let shape = geometry(leaderOffset: 520, leaderContent: 1000, followerContent: 300)

        #expect(
            strategy.followerOffset(for: shape, from: .first)
                != strategy.followerOffset(for: shape, from: .second)
        )
    }

    /// Before the first layout there is nothing to map, and a scroll then
    /// must still move sensibly rather than jumping to the top.
    @Test func anEmptySnapshotFallsBackToProportion() {
        let strategy = ScrollSyncStrategy.markdownPreview(MarkdownPreviewAnchors(), previewSide: .second)

        /// 400 into 800pt of travel is half way, so half way down the
        /// follower's own 1300.
        let offset = strategy.followerOffset(
            for: geometry(leaderOffset: 400, leaderContent: 900, followerContent: 1400),
            from: .first
        )
        #expect(abs(offset - 650) < 1)
    }
}
