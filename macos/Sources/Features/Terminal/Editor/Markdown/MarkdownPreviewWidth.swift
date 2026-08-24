import AppKit
import SwiftUI

/// How wide the rendered document is allowed to run.
///
/// Two answers, because a preview is asked to be two things. A README read on
/// its own is a document, and a document set edge to edge across a 1600-point
/// window runs 200 characters to the line — past any measure a reader can
/// follow, and the reason this setting was asked for. A file being *worked on*
/// beside its source, or a wide table, wants every point the pane has.
///
/// Named for what the reader gets rather than for the mechanism: the mechanism
/// is a text container inset, which is nobody's mental model of a page.
enum MarkdownPreviewWidth: String, CaseIterable, Sendable {
    /// Edge to edge, which is how the preview has always drawn.
    case fluid

    /// A centred column, as wide as `MarkdownStyle.measure`.
    case contained

    /// What pressing the control produces.
    var toggled: MarkdownPreviewWidth {
        self == .fluid ? .contained : .fluid
    }

    /// The glyph and the words picture the arrangement this will *produce*,
    /// not the one already on screen — the same bargain
    /// `SplitPaneDirectionToggle` makes, and for its reason: a toggle showing
    /// its current state leaves the reader deciding whether the icon is a
    /// label or a destination.
    var symbol: String {
        switch toggled {
        case .fluid: "arrow.left.and.right"
        case .contained: "rectangle.center.inset.filled"
        }
    }

    var help: String {
        switch toggled {
        case .fluid: "Use the Full Width"
        case .contained: "Narrow to a Reading Column"
        }
    }

    /// How far the text sits in from each edge of the pane.
    ///
    /// - Parameters:
    ///   - paneWidth: the document view's own width.
    ///   - measure: the column width prose is held to.
    ///   - base: the inset a fluid document keeps, so the first glyph is not
    ///     flush against the edge.
    ///
    /// Symmetrical on purpose, which is the whole trick: `textContainerInset`
    /// applies to both sides, so widening it is what centres the column, with
    /// no second frame to keep in step and nothing for the scroll-anchor
    /// arithmetic to re-learn.
    ///
    /// A pane too narrow to give the gutters stays fluid. Splitting the
    /// remainder anyway would hand a 520-point pane a 10-point margin and a
    /// column of wrapped fragments, which is worse than the full width it
    /// already had.
    static func inset(paneWidth: CGFloat, measure: CGFloat?, base: CGFloat) -> CGFloat {
        guard let measure, measure > 0 else { return base }
        let free = paneWidth - measure
        guard free > base * 2 else { return base }
        return (free / 2).rounded()
    }
}

/// The control that changes the column, in the corner cluster the preview
/// already has.
///
/// Reads and writes the preference itself rather than taking a binding, for
/// the reason the editor's other switches do: the value belongs to the reader
/// and not to this document, so every open preview answers to one setting and
/// a new window opens the way the last one was left.
struct MarkdownWidthToggle: View {
    @AppStorage(EditorSettings.markdownPreviewWidthKey)
    private var stored = EditorSettings.defaultMarkdownPreviewWidth.rawValue

    private var width: MarkdownPreviewWidth {
        MarkdownPreviewWidth(rawValue: stored) ?? EditorSettings.defaultMarkdownPreviewWidth
    }

    var body: some View {
        SidebarIconButton(help: width.help) {
            stored = width.toggled.rawValue
        } label: {
            Image(systemName: width.symbol)
                .font(.system(size: SplitPaneMetrics.controlGlyphSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
