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

        let textView = Self.makeTextView()
        scrollView.documentView = textView
        context.coordinator.textView = textView

        render(into: context.coordinator)
        scrollSync?.attach(scrollView, as: scrollSyncSide)
        publish(to: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        render(into: context.coordinator)
        /// Free when the view has not changed, which matters because this
        /// runs far more often than anything here does.
        scrollSync?.attach(scrollView, as: scrollSyncSide)
        publish(to: context.coordinator)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.anchors?.clear()
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
    private static func makeTextView() -> NSTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = true
        textView.textContainerInset = CGSize(width: 20, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        return textView
    }

    private func render(into coordinator: Coordinator) {
        let style = MarkdownStyle.standard(theme: theme, configuration: configuration)
        let flavor = fileURL.map { MarkdownParser.flavor(forFileName: $0.lastPathComponent) } ?? .markdown

        let fingerprint = Coordinator.Fingerprint(text: text, style: style, fileURL: fileURL)
        guard coordinator.fingerprint != fingerprint else { return }
        coordinator.fingerprint = fingerprint

        let document = MarkdownParser.parse(text, flavor: flavor)
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

    private func publish(to coordinator: Coordinator) {
        guard coordinator.anchors !== anchors else { return }
        coordinator.anchors?.clear()
        coordinator.anchors = anchors
        anchors?.serve(coordinator)
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

        weak var textView: NSTextView?
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
    }
}

/// What the preview can answer about itself once it has laid out.
///
/// A mailbox the host owns and the preview fills in, rather than a callback
/// the preview fires. The difference matters: a synchronised scroll needs to
/// *ask* — "where did line 40 go" — at the moment the other pane moves, and
/// a pane that only announced its own scrolling could not be asked anything.
///
/// Deliberately empty of `@Published`: the host holds this to interrogate
/// the preview, not to be told when it changes, and republishing a SwiftUI
/// view from inside a scroll relay is how two panes start fighting.
@MainActor
final class MarkdownPreviewAnchors: ObservableObject {
    private weak var coordinator: MarkdownPreviewView.Coordinator?

    /// `nonisolated` so a host can write `@StateObject private var anchors =
    /// MarkdownPreviewAnchors()`. A property wrapper's initial value is
    /// evaluated in a nonisolated context even inside a `@MainActor` type —
    /// the same trap `SplitPaneModel` documents for `ScrollSyncLink()` in a
    /// default argument. There is nothing to isolate here anyway: the stored
    /// reference starts nil and only the accessors touch it.
    nonisolated init() {}

    /// Whether a preview is attached and laid out enough to answer.
    var isReady: Bool { coordinator?.output != nil }

    /// Where the preview draws the block that source `line` came from, in
    /// the preview's own coordinates.
    func renderedY(forSourceLine line: Int) -> CGFloat? {
        coordinator?.renderedY(forSourceLine: line)
    }

    /// Which source line the preview is drawing at `y`.
    func sourceLine(forRenderedY y: CGFloat) -> Int? {
        coordinator?.sourceLine(forRenderedY: y)
    }

    /// Internal rather than private so a test can attach a laid-out preview
    /// and check that the mapping answers. Handing over the coordinator is
    /// the whole mechanism, and it is the half that cannot be checked by
    /// reading the code.
    func serve(_ coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func clear() {
        coordinator = nil
    }
}
