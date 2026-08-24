import AppKit
import SwiftUI

/// The rendered half of a markdown file.
///
/// Read-only by design: this is a *preview*, and the editable copy is the
/// other pane. That is also what makes the whole thing cheap — there is no
/// incremental re-layout to get right, no undo stack, no selection to
/// preserve across a re-parse. The document is re-rendered when the text
/// changes and that is the entire update path.
///
/// **Outside `Engine/`, unlike everything else this feature is built from.**
/// The parse, the model, the inline pass and the renderer are all pure and
/// live in the engine; this file is not, because it reaches for
/// `ScrollSyncLink` — app code, in `Editor/Split/`. An engine file naming it
/// would quietly cost the directory its extractability, which is the one
/// thing the boundary test exists to protect. The theme still arrives as a
/// `CodeTheme` value here, exactly as it does inside the engine: being
/// allowed to reach for `ThemePalette` is not a reason to.
struct MarkdownPreviewView: NSViewRepresentable {
    /// The markdown source.
    let text: String

    /// The file this came from, which decides the dialect and resolves
    /// relative image paths. Nil renders as plain markdown with images that
    /// have nowhere to resolve against, which is the right behaviour for an
    /// unsaved buffer.
    var fileURL: URL?

    let theme: CodeTheme
    let configuration: CodeEditorConfiguration

    /// How wide the prose is allowed to run. Applied to the document view's
    /// inset rather than to the render, so changing it re-lays out the same
    /// attributed string instead of parsing the file again.
    var width: MarkdownPreviewWidth = EditorSettings.defaultMarkdownPreviewWidth

    /// The split's scroll link, when the preview sits beside the source.
    ///
    /// Attached to directly rather than through `.synchronizedScroll(_:as:)`,
    /// because this pane builds its own `NSScrollView` and so has nothing to
    /// go looking for — which is the case the link's own documentation says
    /// to use `attach(_:as:)` for.
    var scrollSync: ScrollSyncLink?
    var scrollSyncSide: ScrollSyncSide = .second

    /// Filled in by the preview as it lays out, so the host can ask where a
    /// source line ended up.
    ///
    /// This is the answer to the question the whole hand-written parse
    /// exists to be able to answer, and the host needs it to build a
    /// `ScrollSyncStrategy` — the link takes the mapping as a closure
    /// precisely because neither pane can derive it from heights.
    var anchors: MarkdownPreviewAnchors?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.useThinScrollers()

        let textView = Self.makeTextView()
        scrollView.documentView = textView
        context.coordinator.textView = textView

        render(into: context.coordinator)
        applyWidth(to: context.coordinator)
        join(scrollView, to: context.coordinator)
        publish(to: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        render(into: context.coordinator)
        /// Outside `render`, which returns early when the text and the style
        /// have not changed — and a reader who only pressed the column button
        /// changed neither.
        applyWidth(to: context.coordinator)
        /// Free when the view has not changed, which matters because this
        /// runs far more often than anything here does.
        join(scrollView, to: context.coordinator)
        publish(to: context.coordinator)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.anchors?.clear()
    }

    /// Puts this pane on the split's scroll link, and says how it should be
    /// followed.
    ///
    /// **The strategy is set here, not left to the host, because the link is
    /// shared.** The diff puts `.absolute` on it — correct for two panes
    /// padded onto one row grid, and completely wrong for raw markdown
    /// against its rendered form, where the same offset means different
    /// places. A preview that inherited whatever the last presentation left
    /// behind would scroll to nonsense, so the pane that knows the answer
    /// states it on every attach.
    ///
    /// `isEnabled` is deliberately *not* touched: whether the two panes move
    /// together at all is the reader's preference and the host's to own.
    private func join(_ scrollView: NSScrollView, to coordinator: Coordinator) {
        guard let scrollSync else { return }
        scrollSync.attach(scrollView, as: scrollSyncSide)
        scrollSync.strategy = anchors.map {
            .markdownPreview($0, previewSide: scrollSyncSide)
        } ?? .proportional
    }

    /// ⚠️ **TextKit 1, deliberately, and the opposite of `CodeTextView`.**
    ///
    /// Block decoration in this preview is `NSTextBlock` and `NSTextTable` —
    /// the quote bar, the panel behind a fence, the grid of a table — and
    /// those are laid out by the TextKit 1 layout manager. TextKit 2 does
    /// not draw them, so a preview left on the modern path renders tables as
    /// a column of bare cells with no borders and quotes with no bar.
    ///
    /// The editor's reason for insisting on TextKit 2 does not apply here:
    /// it needs viewport-only layout because a source file can be
    /// megabytes, while a rendered README is laid out once and is a few
    /// hundred lines. Touching `layoutManager` is what performs the
    /// downgrade, and building the stack by hand is the version that says
    /// so on purpose rather than by accident.
    ///
    /// Internal rather than private so a test can put the real thing inside a
    /// real `NSScrollView`: the sizing below is the whole difference between a
    /// document that scrolls and one clipped to the viewport, and nothing in
    /// the parse or the render can tell those two apart.
    static func makeTextView() -> MarkdownDocumentTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = MarkdownDocumentTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = true
        textView.textContainerInset = CGSize(
            width: MarkdownDocumentTextView.baseInset,
            height: MarkdownDocumentTextView.baseInset
        )
        textView.isVerticallyResizable = true
        /// The other half of the resizing recipe, and without it the preview
        /// could not be scrolled past its first screen. `NSTextView(frame:
        /// textContainer:)` leaves `maxSize` at the initial frame — zero here
        /// — and a text view only grows up to `maxSize`, so a README laid out
        /// 5000pt tall stayed exactly as tall as the clip view it sits in:
        /// everything below the fold was rendered and unreachable, with a
        /// document view the same height as the viewport for the scroller to
        /// find no travel in. `minSize` is `.zero` for the same reason it is
        /// in `CodeTextView`; a text view never shrinks below its clip view
        /// anyway, so a short document still fills the pane.
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        return textView
    }

    /// The parse, with the dialect taken from the file's own name.
    ///
    /// Its own function, and internal, because this one line is the whole
    /// difference between an `.mdx` file rendering as MDX and rendering as
    /// prose — and it fails *silently*: forget the flavor and `import
    /// Callout from './c'` is drawn as a paragraph rather than as a module,
    /// with nothing to indicate anything was skipped. That is not a
    /// hypothetical; a probe of mine dropped the argument and the output
    /// looked plausible enough that only reading it caught it. A seam a
    /// test can hold is worth more here than one saved line.
    static func document(text: String, fileURL: URL?) -> MarkdownDocument {
        let flavor = fileURL.map { MarkdownParser.flavor(forFileName: $0.lastPathComponent) } ?? .markdown
        return MarkdownParser.parse(text, flavor: flavor)
    }

    /// What the preview draws with, derived from the editor's own font and the
    /// terminal's palette. Cheap enough to rebuild per pass, and derived in one
    /// place so the render and the column cannot disagree about the measure.
    private var style: MarkdownStyle {
        .standard(theme: theme, configuration: configuration)
    }

    /// Gives the document view its column, or takes it away.
    ///
    /// The measure comes from the style, so a reader who makes the editor's
    /// font bigger gets a wider column with the same number of characters on
    /// the line — which is the whole point of deriving it from font metrics.
    private func applyWidth(to coordinator: Coordinator) {
        coordinator.textView?.measure = width == .contained ? style.measure : nil
    }

    private func render(into coordinator: Coordinator) {
        let style = self.style

        let fingerprint = Coordinator.Fingerprint(text: text, style: style, fileURL: fileURL)
        guard coordinator.fingerprint != fingerprint else { return }
        coordinator.fingerprint = fingerprint

        let document = Self.document(text: text, fileURL: fileURL)
        let renderer = MarkdownRenderer(style: style, baseURL: fileURL?.deletingLastPathComponent())
        let output = renderer.render(document)

        coordinator.output = output
        coordinator.textView?.backgroundColor = theme.background
        coordinator.textView?.textStorage?.setAttributedString(output.text)
        coordinator.textView?.linkTextAttributes = [
            .foregroundColor: style.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
    }

    /// Hands the host a fresh reading of where each block ended up.
    ///
    /// Taken as a **snapshot of numbers** rather than left as a live query
    /// into the layout manager, for two reasons. A scroll relay fires many
    /// times a second and this way it costs an array lookup instead of a
    /// glyph-range measurement; and the snapshot is plain data, so the
    /// mapping can be read from the scroll strategy's closure without any
    /// actor isolation to escape from.
    ///
    /// Refreshed on every update, which is what keeps it honest when the
    /// document is edited or the pane is resized — a stale snapshot only
    /// ever means a slightly-off scroll that the next update corrects.
    private func publish(to coordinator: Coordinator) {
        guard let anchors else {
            coordinator.anchors?.clear()
            coordinator.anchors = nil
            return
        }
        coordinator.anchors = anchors
        anchors.update(
            to: coordinator.scrollAnchors(),
            sourceLineCount: MarkdownParser.lines(of: text).count
        )
    }

    /// Holds the rendered output, so both directions of the scroll mapping
    /// can be answered without re-parsing.
    @MainActor
    final class Coordinator: NSObject {
        struct Fingerprint: Equatable {
            let text: String
            let style: MarkdownStyle
            let fileURL: URL?
        }

        weak var textView: MarkdownDocumentTextView?
        var output: MarkdownRenderer.Output?
        var fingerprint: Fingerprint?
        var anchors: MarkdownPreviewAnchors?

        /// Where the rendered document draws the block that source `line`
        /// came from.
        func renderedY(forSourceLine line: Int) -> CGFloat? {
            guard let output, let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let offset = output.renderedOffset(forSourceLine: line)
            else { return nil }

            let length = textView.textStorage?.length ?? 0
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: min(offset, length), length: 0),
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            return rect.minY + textView.textContainerInset.height
        }

        /// The source line whose block the rendered document is drawing at
        /// `y` — the same question from the other end.
        func sourceLine(forRenderedY y: CGFloat) -> Int? {
            guard let output, let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return nil }

            let point = CGPoint(x: 0, y: max(0, y - textView.textContainerInset.height))
            let index = layoutManager.characterIndex(
                for: point,
                in: container,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            return output.sourceLine(forRenderedOffset: index)
        }

        /// Every block reduced to "this source line was drawn at this y".
        ///
        /// Measured once per update. Layout is forced first because the
        /// rects are asked for immediately after the text was replaced, and
        /// TextKit is entitled to have laid out nothing yet — which reads
        /// back as every block sitting at zero.
        func scrollAnchors() -> [MarkdownScrollAnchor] {
            guard let output, let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return [] }

            layoutManager.ensureLayout(for: container)
            return output.anchors.compactMap { anchor in
                let line = anchor.sourceLines.lowerBound
                guard let y = renderedY(forSourceLine: line) else { return nil }
                return MarkdownScrollAnchor(sourceLine: line, renderedY: y)
            }
        }
    }
}

/// The preview's document view, which centres its own column.
///
/// A subclass for one reason: the inset depends on the pane's width, and a
/// `NSViewRepresentable` is told when its *value* changes and never when its
/// view is resized. Dragging the window edge is exactly when the gutters have
/// to be recomputed, so the view that knows its own width does the arithmetic.
final class MarkdownDocumentTextView: NSTextView {
    /// The inset a fluid document keeps: enough that the first glyph is not
    /// flush against the edge of the pane, and no more.
    static let baseInset: CGFloat = 20

    /// How wide prose may run, or nil for edge to edge.
    var measure: CGFloat? {
        didSet {
            guard measure != oldValue else { return }
            applyMeasure()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyMeasure()
    }

    /// ⚠️ Guarded against the loop it would otherwise be. Setting
    /// `textContainerInset` invalidates layout, layout can resize a vertically
    /// resizable text view, and a resize comes back through `setFrameSize` —
    /// so this must be a no-op once the inset is right, not merely idempotent.
    private func applyMeasure() {
        let inset = MarkdownPreviewWidth.inset(
            paneWidth: bounds.width,
            measure: measure,
            base: Self.baseInset
        )
        guard abs(textContainerInset.width - inset) > 0.5 else { return }
        textContainerInset = CGSize(width: inset, height: Self.baseInset)
    }
}

/// One block, reduced to the two numbers a synchronised scroll needs.
struct MarkdownScrollAnchor: Equatable {
    /// The block's first source line.
    let sourceLine: Int

    /// Where the preview drew it, in the preview's own coordinates.
    let renderedY: CGFloat
}

/// What the preview can say about itself once it has laid out.
///
/// A mailbox the host owns and the preview refills on every update, rather
/// than a callback the preview fires. The difference matters: a synchronised
/// scroll needs to *ask* — "where did line 40 go" — at the moment the other
/// pane moves, and a pane that only announced its own scrolling could not be
/// asked anything.
///
/// Holds **numbers, not a view**. Everything below is arithmetic over an
/// array, which is what lets the scroll strategy read it from a plain
/// closure with no actor to hop and no layout to re-measure on every frame
/// of a scroll.
///
/// Deliberately empty of `@Published`: the host holds this to interrogate
/// the preview, not to be told when it changes, and republishing a SwiftUI
/// view from inside a scroll relay is how two panes start fighting.
final class MarkdownPreviewAnchors: ObservableObject {
    /// Ascending in both fields, because the renderer emits blocks in order
    /// and a later block is always drawn lower.
    private(set) var anchors: [MarkdownScrollAnchor] = []

    /// How many lines the markdown had, so the source pane's average line
    /// height can be recovered from its content height without this ever
    /// having to know the editor's font.
    private(set) var sourceLineCount = 0

    init() {}

    /// Whether a preview is attached and laid out enough to answer.
    var isReady: Bool { !anchors.isEmpty && sourceLineCount > 0 }

    func update(to anchors: [MarkdownScrollAnchor], sourceLineCount: Int) {
        self.anchors = anchors
        self.sourceLineCount = sourceLineCount
    }

    func clear() {
        anchors = []
        sourceLineCount = 0
    }

    /// Where the preview draws the block that source `line` belongs to.
    ///
    /// The block, not the line: a fenced block is many source lines at one
    /// rendered offset, so the honest answer for any line inside it is where
    /// the block starts.
    func renderedY(forSourceLine line: Int) -> CGFloat? {
        var found: CGFloat?
        for anchor in anchors {
            if anchor.sourceLine > line { break }
            found = anchor.renderedY
        }
        return found ?? anchors.first?.renderedY
    }

    /// Which source line the preview is drawing at `y`.
    func sourceLine(forRenderedY y: CGFloat) -> Int? {
        var found: Int?
        for anchor in anchors {
            if anchor.renderedY > y { break }
            found = anchor.sourceLine
        }
        return found ?? anchors.first?.sourceLine
    }
}

extension ScrollSyncStrategy {
    /// Raw markdown against its rendered preview, matched block by block.
    ///
    /// The mapping the hand-written parser exists to make possible. Every
    /// block remembers the source lines it came from, so "the reader is
    /// looking at line 40" can be answered in the preview's coordinates and
    /// the other way round — which no arithmetic over the two panes' heights
    /// could recover, since a fence renders shorter than its source and a
    /// heading renders taller.
    ///
    /// **Asymmetric, and that is the whole point of being told the side.**
    /// Source line 12 landing at rendered y=400 does not mean y=400 came
    /// from line 12; the relation is many-to-one. Each direction therefore
    /// composes differently, and a strategy that ignored `side` would push
    /// the source→rendered answer back into the source pane the moment the
    /// reader scrolled the preview.
    ///
    /// The source pane's line height is *derived* — its content height over
    /// its line count — rather than taken as a parameter. That keeps the
    /// editor's font, line spacing and insets out of this entirely, and it
    /// stays right when any of them change.
    ///
    /// Falls back to `.proportional` whenever the preview has not laid out
    /// yet or a lookup comes back empty, so a scroll during the first frame
    /// moves sensibly instead of jumping to the top.
    static func markdownPreview(
        _ anchors: MarkdownPreviewAnchors,
        previewSide: ScrollSyncSide
    ) -> ScrollSyncStrategy {
        ScrollSyncStrategy { geometry, side in
            let fallback = geometry.leaderProgress * geometry.followerScrollableLength
            guard anchors.isReady else { return fallback }

            if side == previewSide {
                guard let line = anchors.sourceLine(forRenderedY: geometry.leaderOffset) else {
                    return fallback
                }
                let lineHeight = geometry.followerContentLength / CGFloat(anchors.sourceLineCount)
                return CGFloat(line) * lineHeight
            }

            let lineHeight = geometry.leaderContentLength / CGFloat(anchors.sourceLineCount)
            guard lineHeight > 0 else { return fallback }
            let line = Int(geometry.leaderOffset / lineHeight)
            return anchors.renderedY(forSourceLine: line) ?? fallback
        }
    }
}
