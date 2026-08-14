import AppKit
@testable import Ghostty
import Testing

/// Everything the completion list decides, decided without a window.
///
/// Not one test here presents a panel. `NSWindow.isVisible` only becomes true
/// by asking the window server to display something, and doing that from this
/// test host — which has no running `NSApplication` event loop pumping the
/// replies — hangs the call forever instead of returning, taking the whole
/// suite with it. The two tests at the bottom that do build a panel prove the
/// guards that return *before* `orderFront`, which is the same technique
/// `CodeHoverPersistenceTests` uses with an empty `CodeHoverInfo`.
///
/// A click is tested as index arithmetic for the sibling reason: driving a real
/// one means `mouseDown`, whose superclass implementation runs an
/// event-tracking loop waiting for a mouse-up that never comes outside a live
/// window.
@MainActor
struct CodeCompletionPanelTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Concrete colours rather than `CodeTheme.fallback`, whose `.textColor` is
    /// a dynamic catalog colour that has no component to read outside a drawing
    /// context.
    private let theme = CodeTheme(
        foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
        background: NSColor(calibratedWhite: 0.1, alpha: 1),
        tokens: [.function: NSColor(calibratedRed: 0.3, green: 0.6, blue: 1, alpha: 1)],
        lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
        currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
        currentLineBackground: nil
    )

    private func item(
        _ label: String,
        kind: CodeCompletionItem.Kind = .function,
        detail: String? = nil,
        filterText: String? = nil,
        isPreselected: Bool = false
    ) -> CodeCompletionItem {
        CodeCompletionItem(
            kind: kind,
            label: label,
            detail: detail,
            filterText: filterText,
            isPreselected: isPreselected
        )
    }

    // MARK: - Metrics

    /// The list's rhythm follows the file's, so a bigger editor font gives
    /// taller rows rather than a denser list.
    @Test func rowHeightFollowsTheEditorsFont() {
        #expect(CodeCompletionPanel.rowHeight(for: font) == ceil(12 * 1.6))
        #expect(
            CodeCompletionPanel.rowHeight(for: .monospacedSystemFont(ofSize: 18, weight: .regular))
                == ceil(18 * 1.6)
        )
    }

    @Test func aLongListStopsGrowingAtTwelveRows() {
        #expect(CodeCompletionPanel.visibleRowCount(of: 300) == CodeCompletionPanel.maximumVisibleRows)
        #expect(CodeCompletionPanel.visibleRowCount(of: 3) == 3)
        #expect(CodeCompletionPanel.visibleRowCount(of: 0) == 0)
    }

    /// The window is sized for what it shows, not for what it holds — the rest
    /// scrolls. A list sized for three hundred rows would be taller than the
    /// display, and the clamp that keeps a window on screen would decide which
    /// end of it survived.
    @Test func theWindowIsSizedForTheVisibleRowsAndNotTheWholeList() {
        let size = CodeCompletionPanel.contentSize(rowCount: 300, width: 300, rowHeight: 20, inset: 4)

        #expect(size.height == CGFloat(CodeCompletionPanel.maximumVisibleRows) * 20 + 8)
        #expect(size.width == 300)
    }

    @Test func widthIsClampedAtBothEnds() {
        let narrow = CodeCompletionPanel.measuredWidth(for: [item("ab")], font: font, chrome: 40)
        let wide = CodeCompletionPanel.measuredWidth(
            for: [item(String(repeating: "x", count: 300))],
            font: font,
            chrome: 40
        )

        #expect(narrow == CodeCompletionPanel.minimumWidth)
        #expect(wide == CodeCompletionPanel.maximumWidth)
    }

    /// The reason the sample size exists: a single enormous label past row fifty
    /// must not widen the list, because measuring every row of a several-hundred
    /// item answer happens on the keystroke path and nobody scrolls that far
    /// before typing another character.
    @Test func onlyTheFirstFiftyRowsAreMeasured() {
        var items = (0..<50).map { item("ab\($0)") }
        items.append(item(String(repeating: "x", count: 300)))

        let width = CodeCompletionPanel.measuredWidth(for: items, font: font, chrome: 40)

        #expect(width == CodeCompletionPanel.minimumWidth)
        #expect(items.count > CodeCompletionPanel.measurementSampleSize)
    }

    /// The detail column is measured too, or six overloads distinguished only by
    /// their signatures all truncate to the same ellipsis.
    @Test func theDetailColumnIsPartOfTheMeasurement() {
        let plain = CodeCompletionPanel.measuredWidth(for: [item("connect")], font: font, chrome: 40)
        let detailed = CodeCompletionPanel.measuredWidth(
            for: [item("connect", detail: String(repeating: "Options", count: 6))],
            font: font,
            chrome: 40
        )

        #expect(detailed > plain)
    }

    // MARK: - Selection

    @Test func downMovesToTheNextRow() {
        #expect(CodeCompletionPanel.selection(.down, from: 0, count: 5, pageSize: 12) == 1)
    }

    /// The list is a ring you steer with, not a document you scroll: down at the
    /// last row is how you get back to the first.
    @Test func downWrapsAtTheEnd() {
        #expect(CodeCompletionPanel.selection(.down, from: 4, count: 5, pageSize: 12) == 0)
    }

    @Test func upWrapsAtTheStart() {
        #expect(CodeCompletionPanel.selection(.up, from: 0, count: 5, pageSize: 12) == 4)
    }

    /// A page is a distance, and wrapping a distance lands somewhere unrelated
    /// to where the eye was — so these clamp where up and down wrap.
    @Test func pageMovementsClampInsteadOfWrapping() {
        #expect(CodeCompletionPanel.selection(.pageDown, from: 0, count: 5, pageSize: 12) == 4)
        #expect(CodeCompletionPanel.selection(.pageUp, from: 0, count: 5, pageSize: 12) == 0)
        #expect(CodeCompletionPanel.selection(.pageDown, from: 0, count: 100, pageSize: 12) == 12)
    }

    @Test func firstAndLastGoToTheEnds() {
        #expect(CodeCompletionPanel.selection(.first, from: 7, count: 20, pageSize: 12) == 0)
        #expect(CodeCompletionPanel.selection(.last, from: 7, count: 20, pageSize: 12) == 19)
    }

    /// `-1` is `NSTableView`'s own "no row", and the value `selectedItem` reads
    /// as nil — so an empty list answers it for every key rather than reporting
    /// a row that is not there.
    @Test func anEmptyListHasNoSelectionWhicheverKeyIsPressed() {
        let movements: [CodeCompletionPanel.Movement] = [.up, .down, .pageUp, .pageDown, .first, .last]

        for movement in movements {
            #expect(CodeCompletionPanel.selection(movement, from: 0, count: 0, pageSize: 12) == -1)
        }
    }

    /// A refilter can leave the stored index past the end of the shorter list,
    /// and the next arrow key must land somewhere real rather than crashing or
    /// selecting nothing.
    @Test func anIndexLeftOverFromALongerListIsBroughtBackInside() {
        #expect(CodeCompletionPanel.selection(.down, from: 99, count: 3, pageSize: 12) == 0)
        #expect(CodeCompletionPanel.selection(.up, from: -5, count: 3, pageSize: 12) == 2)
    }

    /// A page size of zero — a list shorter than one row, arithmetically — still
    /// has to move by something, or the key does nothing at all.
    @Test func aPageIsNeverZeroRows() {
        #expect(CodeCompletionPanel.selection(.pageDown, from: 0, count: 5, pageSize: 0) == 1)
    }

    // MARK: - Initial selection

    @Test func theTopRowIsSelectedWhenTheServerAsksForNothing() {
        #expect(CodeCompletionPanel.initialSelection(in: [item("a"), item("b")]) == 0)
    }

    /// A server sets preselection where it knows something the ranking cannot —
    /// the type expected at this position, usually — so it wins over the top
    /// row.
    @Test func theServersPreselectionWins() {
        let items = [item("a"), item("b", isPreselected: true), item("c")]

        #expect(CodeCompletionPanel.initialSelection(in: items) == 1)
    }

    @Test func anEmptyListSelectsNothing() {
        #expect(CodeCompletionPanel.initialSelection(in: []) == -1)
    }

    // MARK: - Click targeting

    @Test func aClickLandsOnTheRowUnderIt() {
        #expect(CodeCompletionPanel.rowIndex(atY: 25, rowHeight: 20, count: 5) == 1)
        #expect(CodeCompletionPanel.rowIndex(atY: 0, rowHeight: 20, count: 5) == 0)
        #expect(CodeCompletionPanel.rowIndex(atY: 99, rowHeight: 20, count: 5) == 4)
    }

    @Test func aClickPastTheLastRowLandsNowhere() {
        #expect(CodeCompletionPanel.rowIndex(atY: 200, rowHeight: 20, count: 5) == nil)
        #expect(CodeCompletionPanel.rowIndex(atY: -4, rowHeight: 20, count: 5) == nil)
        #expect(CodeCompletionPanel.rowIndex(atY: 10, rowHeight: 20, count: 0) == nil)
    }

    // MARK: - Emphasis

    @Test func theMatchedCharactersAreReported() {
        let ranges = CodeCompletionPanel.highlightRanges(query: "con", item: item("connect"))

        #expect(ranges == [NSRange(location: 0, length: 3)])
    }

    /// The one that matters. The filter's ranges are offsets into what it
    /// matched — `filterText ?? label` — and TypeScript offers an optional
    /// member as `label: "foo?"` with `filterText: "foo"`. Applying those offsets
    /// to the label would emphasise the wrong characters, silently, on exactly
    /// the rows where the label is doing the most work.
    @Test func aFilterTextThatDiffersFromTheLabelSuppressesEmphasis() {
        let optional = item("count?", filterText: "count")

        #expect(CodeCompletionPanel.highlightRanges(query: "cou", item: optional).isEmpty)
    }

    @Test func aFilterTextEqualToTheLabelStillEmphasises() {
        let plain = item("count", filterText: "count")

        #expect(CodeCompletionPanel.highlightRanges(query: "cou", item: plain) == [NSRange(location: 0, length: 3)])
    }

    @Test func aQueryThatDoesNotMatchEmphasisesNothing() {
        #expect(CodeCompletionPanel.highlightRanges(query: "zzz", item: item("connect")).isEmpty)
    }

    @Test func theMatchedCharactersAreDrawnBolderThanTheRest() {
        let text = CodeCompletionPanel.labelText(
            for: item("connect"),
            query: "con",
            theme: theme,
            font: font
        )

        let matched = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let rest = text.attribute(.font, at: 5, effectiveRange: nil) as? NSFont

        #expect(matched != nil)
        #expect(matched != rest, "the matched prefix has to read differently from the rest of the label")
    }

    /// The label loses its tail and the detail loses its head, and the asymmetry
    /// is the point: a detail is a qualified name whose distinguishing half is at
    /// the end, so cutting its tail leaves six rows all reading the same prefix.
    @Test func theTwoColumnsTruncateFromOppositeEnds() {
        let label = CodeCompletionPanel.labelText(for: item("connect"), query: "", theme: theme, font: font)
        let detail = CodeCompletionPanel.detailText("react/index", theme: theme, font: font)

        let labelStyle = label.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let detailStyle = detail.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        #expect(labelStyle?.lineBreakMode == .byTruncatingTail)
        #expect(detailStyle?.lineBreakMode == .byTruncatingHead)
        #expect(detailStyle?.alignment == .right)
    }

    // MARK: - Icons

    /// Every kind has to resolve to a symbol that actually ships in this OS.
    /// A name that does not returns nil from AppKit and leaves the icon column
    /// silently blank for one kind — which reads as a theming bug rather than a
    /// missing glyph.
    @Test func everyKindResolvesToARealSymbol() {
        for kind in CodeCompletionItem.Kind.allCases {
            let image = CodeCompletionPanel.icon(for: kind, color: .white, pointSize: 12)
            #expect(image != nil, "\(kind.rawValue) has no SF Symbol named \(kind.symbolName)")
        }
    }

    /// The band is drawn from the theme rather than taken from `NSTableView`,
    /// which would paint the inactive grey it reserves for a background window —
    /// permanently, since this panel is never key.
    @Test func theSelectionBandComesFromTheThemeAndLetsTheRowThrough() {
        let color = CodeCompletionPanel.selectionColor(for: theme)

        #expect(color.alphaComponent > 0)
        #expect(color.alphaComponent < 1, "an opaque band would hide the row it is highlighting")
    }

    // MARK: - The guards that keep a test off the window server

    /// An empty list dismisses instead of presenting, which is what stops this
    /// test reaching `orderFront` — the same guard the feature needs anyway,
    /// since a list with no rows is not a list.
    @Test func anEmptyListIsNotPresented() {
        let panel = CodeCompletionPanel()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        panel.present(
            [],
            query: "con",
            theme: theme,
            font: font,
            anchor: NSRect(x: 0, y: 0, width: 10, height: 16),
            over: view
        )

        #expect(!panel.isOpen)
        #expect(panel.selectedItem == nil)
    }

    /// A view with no window has nothing to hang a child window off, and a
    /// floating panel that outlives its parent is a card stranded on an empty
    /// desktop.
    @Test func aListWithNoWindowToHangFromIsNotPresented() {
        let panel = CodeCompletionPanel()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        panel.present(
            [item("connect")],
            query: "con",
            theme: theme,
            font: font,
            anchor: NSRect(x: 0, y: 0, width: 10, height: 16),
            over: view
        )

        #expect(!panel.isOpen)
    }

    /// A zero-height anchor means the caller could not work out where the prefix
    /// starts, and a list pinned to the bottom-left corner of the display is
    /// worse than no list at all.
    @Test func aListWithNoAnchorIsNotPresented() {
        let panel = CodeCompletionPanel()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        panel.present(
            [item("connect")],
            query: "con",
            theme: theme,
            font: font,
            anchor: .zero,
            over: view
        )

        #expect(!panel.isOpen)
    }

    /// The property the rest of the suite reads to know whether the list is up.
    /// Answered from the panel's own state rather than from `isVisible`, which
    /// only becomes true by asking the window server.
    @Test func aPanelThatWasNeverPresentedIsNotOpen() {
        #expect(!CodeCompletionPanel().isOpen)
    }
}
