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
/// The host owns the toggle and the split; this owns what is inside them.
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

    /// Where the reader is in the *raw* pane, so the preview can follow.
    ///
    /// A line number rather than a scroll offset: the two panes have
    /// unrelated geometry — one line of markdown can be a heading twice the
    /// height or a fence that renders shorter than its source — so a
    /// fraction of the way down one is not a fraction of the way down the
    /// other. Carries an identity for the same reason `CodeTextView.reveal`
    /// does: asking twice for the same line has to still scroll.
    var scrollToSourceLine: (id: Int, line: Int)?

    /// Reports the line the preview scrolled to, for the other direction.
    var onScrollToSourceLine: ((Int) -> Void)?

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
        context.coordinator.scrollView = scrollView
        context.coordinator.onScrollToSourceLine = onScrollToSourceLine
        context.coordinator.observeScrolling()

        render(into: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onScrollToSourceLine = onScrollToSourceLine
        render(into: context.coordinator)

        if let request = scrollToSourceLine, context.coordinator.lastRevealed != request.id {
            context.coordinator.lastRevealed = request.id
            context.coordinator.reveal(sourceLine: request.line)
        }
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

    /// Holds the rendered output so scrolling can be answered in both
    /// directions without re-parsing.
    final class Coordinator: NSObject {
        struct Fingerprint: Equatable {
            let text: String
            let style: MarkdownStyle
            let fileURL: URL?
        }

        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var output: MarkdownRenderer.Output?
        var fingerprint: Fingerprint?
        var lastRevealed: Int?
        var onScrollToSourceLine: ((Int) -> Void)?

        /// Set while the preview is scrolling itself, so following the raw
        /// pane does not bounce straight back and fight it.
        private var isFollowing = false

        func observeScrolling() {
            guard let clipView = scrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func reveal(sourceLine: Int) {
            guard let output, let textView,
                  let offset = output.renderedOffset(forSourceLine: sourceLine),
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }

            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: min(offset, textView.textStorage?.length ?? 0), length: 0),
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)

            isFollowing = true
            defer { isFollowing = false }
            textView.scroll(CGPoint(x: 0, y: max(0, rect.minY - textView.textContainerInset.height)))
        }

        @objc private func scrolled() {
            guard !isFollowing, let onScrollToSourceLine, let output, let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let clipView = scrollView?.contentView
            else { return }

            let top = CGPoint(
                x: 0,
                y: clipView.bounds.origin.y + textView.textContainerInset.height
            )
            let index = layoutManager.characterIndex(
                for: top,
                in: container,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard let line = output.sourceLine(forRenderedOffset: index) else { return }
            onScrollToSourceLine(line)
        }
    }
}
