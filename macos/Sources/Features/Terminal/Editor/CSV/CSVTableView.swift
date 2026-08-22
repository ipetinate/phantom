import AppKit
import SwiftUI

/// A delimited file, drawn as the table it describes.
///
/// Read-only, and cheap for the same reason `MarkdownPreviewView` is: this is
/// a *rendering* of a file whose editable copy is the source presentation, so
/// there is no incremental re-layout to get right, no selection to preserve
/// across a re-parse, and no undo stack. The text changes, the table is built
/// again, and that is the whole update path.
///
/// **Lazy, deliberately.** A CSV out of a warehouse query is routinely tens
/// of thousands of rows, and a `VStack` of every one of them would lay out
/// the entire file before the first screen appeared. Everything drawn here is
/// inside a `LazyVStack` and every size the scroll view needs is arithmetic
/// over the column layout, so nothing in a frame's work grows with the number
/// of rows.
struct CSVTableView: View {
    let text: String
    let theme: CodeTheme
    let configuration: CodeEditorConfiguration

    @State private var cache = CSVDocumentCache()

    var body: some View {
        content(cache.document(for: text))
    }

    @ViewBuilder
    private func content(_ document: CSVDocument) -> some View {
        if document.table.isEmpty {
            /// Reached by an empty file and by one holding nothing but blank
            /// lines. Saying so is the point: an empty grid with a header bar
            /// and no rows is how a reader concludes the viewer is broken.
            note("Nothing to show — this file has no rows.")
        } else {
            grid(document)
        }
    }

    /// Paints no base colour of its own, which is the same decision
    /// `GitDiffPane` documents at length: the host puts a single layer behind
    /// the whole pane, so a solid theme colour here would be a slab in a
    /// window the reader made translucent, and a seam where the table meets
    /// the source beside it. The stripes are alpha washes over whatever that
    /// layer is showing; the pinned header is the one deliberate exception,
    /// for the reason stated on it.
    private func grid(_ document: CSVDocument) -> some View {
        let table = document.table
        let layout = document.layout
        let metrics = CSVTableMetrics(
            layout: layout,
            rowCount: table.rows.count,
            font: configuration.font
        )

        return GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(table.rows.indices, id: \.self) { index in
                            row(index, table.rows[index], layout: layout, metrics: metrics)
                        }

                        if table.rows.isEmpty {
                            note("This file has a header and no rows under it.")
                                .frame(height: metrics.rowHeight * 3)
                        }
                    } header: {
                        header(table.columns, layout: layout, metrics: metrics)
                    }
                }
                /// Both dimensions floored at the viewport's, for the two
                /// reasons the diff pane gives. The width so a stripe runs the
                /// full width of the pane instead of stopping where the last
                /// column ends, which is what makes it read as a band rather
                /// than a smear. The height because a scroll view with both
                /// axes centres content smaller than itself, and a table of
                /// four rows would otherwise float in the middle of the pane.
                .frame(
                    width: max(metrics.contentWidth, viewport.size.width),
                    alignment: .leading
                )
                .frame(minHeight: viewport.size.height, alignment: .top)
                /// A document, so its scrollers carry the content weight
                /// rather than whatever System Settings says — which for
                /// "always show scroll bars" is the wide legacy bar the rest
                /// of this window no longer has.
                .background(alignment: .top) { OverlayScrollers(weight: .content) }
            }
            /// So a cell can be copied out. A table you cannot take a value
            /// from is a table you have to switch back to source to use.
            .textSelection(.enabled)
        }
    }

    /// The column names, pinned so they are still there at row 4000.
    ///
    /// **The one thing in this pane that paints an opaque colour**, and the
    /// exception is the whole reason the header works: rows slide underneath
    /// it, and a wash would let them read straight through the names. In a
    /// translucent window that costs one strip of solid colour at the top of
    /// the pane, which is a far better trade than a header you cannot read
    /// while scrolling.
    private func header(
        _ columns: [String],
        layout: CSVColumnLayout,
        metrics: CSVTableMetrics
    ) -> some View {
        HStack(spacing: 0) {
            gutter(nil, metrics: metrics)

            ForEach(columns.indices, id: \.self) { column in
                cell(
                    columns[column],
                    column: column,
                    layout: layout,
                    metrics: metrics,
                    font: headerFont
                )
            }

            Spacer(minLength: 0)
        }
        .frame(height: metrics.headerHeight)
        .background(Color(nsColor: theme.background))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: theme.foreground.withAlphaComponent(0.28)))
                .frame(height: CSVTableMetrics.ruleWidth)
        }
    }

    /// One row, striped on the odd ones.
    ///
    /// Striping rather than a full grid: twenty columns of ruled cells is a
    /// lot of lines to put on top of a code editor's background, and the
    /// thing a reader actually loses in a wide table is which *row* they are
    /// on — which is what a band fixes and a vertical rule does not.
    private func row(
        _ index: Int,
        _ values: [String],
        layout: CSVColumnLayout,
        metrics: CSVTableMetrics
    ) -> some View {
        HStack(spacing: 0) {
            gutter(index + 1, metrics: metrics)

            ForEach(values.indices, id: \.self) { column in
                cell(
                    values[column],
                    column: column,
                    layout: layout,
                    metrics: metrics,
                    font: cellFont
                )
            }

            Spacer(minLength: 0)
        }
        .frame(height: metrics.rowHeight)
        .background(index.isMultiple(of: 2) ? Color.clear : stripe)
    }

    /// The row number, and the rule that separates it from the data.
    ///
    /// Numbered at all because this sits in a code editor, where every other
    /// pane numbers its lines, and because "the value in row 812" is the only
    /// way to say where something is in a file with no line numbers of its
    /// own. Nil draws the header's blank corner.
    private func gutter(_ number: Int?, metrics: CSVTableMetrics) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: number.map(String.init) ?? "")
                .font(cellFont)
                .foregroundStyle(Color(nsColor: theme.lineNumber))
                .frame(
                    width: metrics.gutterWidth - CSVTableMetrics.gutterInset,
                    alignment: .trailing
                )
                .padding(.trailing, CSVTableMetrics.gutterInset)

            Rectangle()
                .fill(Color(nsColor: theme.foreground.withAlphaComponent(0.12)))
                .frame(width: CSVTableMetrics.ruleWidth)
        }
    }

    /// One cell, truncated at its column's width with the whole value on
    /// hover.
    ///
    /// The tooltip is what makes the width cap defensible: a column is sized
    /// from a sample, so a value wider than every one that was measured will
    /// be cut, and the reader needs somewhere to go for the rest of it that
    /// is not "switch the file back to source and search for it".
    private func cell(
        _ value: String,
        column: Int,
        layout: CSVColumnLayout,
        metrics: CSVTableMetrics,
        font: Font
    ) -> some View {
        let alignment: Alignment = layout.alignment(column) == .trailing ? .trailing : .leading

        return Text(value)
            .font(font)
            .foregroundStyle(Color(nsColor: theme.foreground))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: metrics.textWidth(column), alignment: alignment)
            .padding(.horizontal, CSVTableMetrics.cellInset)
            .help(value)
    }

    private func note(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Monospaced digits so a column of numbers lines up column by column
    /// rather than only glyph by glyph — which is the half of the job that
    /// the right-alignment of a numeric column cannot do on its own.
    private var cellFont: Font {
        Font(configuration.font).monospacedDigit()
    }

    /// Weighted, because a pinned header that is drawn like a row reads as
    /// the first row of data until you notice it never moves.
    private var headerFont: Font {
        Font(configuration.font).weight(.semibold).monospacedDigit()
    }

    /// An alpha over whatever the pane is sitting on rather than a fixed
    /// grey, so it lands correctly on a light theme and a dark one without
    /// this view being told which it is.
    private var stripe: Color {
        Color(nsColor: theme.foreground.withAlphaComponent(0.045))
    }
}
