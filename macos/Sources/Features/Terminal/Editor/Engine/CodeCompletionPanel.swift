import AppKit

/// The list of suggestions that opens under the caret as you type.
///
/// A non-activating child window rather than an `NSPopover`, for the reason
/// written at the top of `CodeHoverPanel`: a popover's window takes key status,
/// which pulls the insertion point out of the text view — the caret stops
/// blinking and the selection greys out.
///
/// **`canBecomeKey` is `false` unconditionally, and that is the one line of this
/// class nobody may "unify" with the hover card.** `CodeHoverPanel` sets
/// `becomesKeyOnlyIfNeeded = true` because its prose is selectable, and copying
/// that line here is fatal rather than merely wrong: this panel has rows you
/// click, so the first click would hand it key status, the caret would stop
/// blinking, the text view would stop receiving the arrow keys that navigate
/// this very list, and the list would become unnavigable in the same gesture
/// that opened it. The two panels share **only** `PanelPlacement`.
///
/// Everything the list *decides* — which row a key moves to, how many rows are
/// visible, how wide it measures, which row a click landed on — is a `static`
/// taking values, and only the drawing touches a window. A test host has no
/// running `NSApplication` event loop, so anything that reaches `orderFront`
/// hangs the call forever and takes the whole suite with it; the guard at the
/// top of `present` returns before that for an empty list, which is how the
/// tests get near this class at all.
final class CodeCompletionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    /// Which way a key moves the selection.
    ///
    /// A value rather than a selector, so the arithmetic below can be tested
    /// without an `NSEvent` — the view translates `doCommand(by:)` into one of
    /// these and this class never learns that AppKit was involved.
    enum Movement: Equatable, Sendable {
        case up
        case down
        case pageUp
        case pageDown
        case first
        case last
    }

    /// Past this the list scrolls rather than growing down the screen. Twelve
    /// is about as many rows as are worth scanning before it is quicker to type
    /// another character.
    static let maximumVisibleRows = 12

    /// How many rows are measured to decide the list's width.
    ///
    /// `gopls` answers with hundreds of items and this runs on the keystroke
    /// path, so measuring all of them costs real time on every character. Fifty
    /// is past anywhere a reader scrolls before typing again, and a row wider
    /// than the window it lands in truncates — which is what the width clamp
    /// below already accepts for the very longest label.
    static let measurementSampleSize = 50

    /// Narrow enough to sit beside code, wide enough for a real signature in
    /// the detail column.
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 520

    /// Called when a row is chosen, by click or by the accept key.
    var onAccept: ((CodeCompletionItem) -> Void)?

    /// Called whenever the highlighted row changes, including when the list is
    /// first filled.
    ///
    /// This is what drives the documentation pane: the host hears the new row
    /// here and goes and asks for its documentation.
    var onSelectionChange: ((CodeCompletionItem?) -> Void)?

    /// Called when the info glyph on the highlighted row is clicked.
    ///
    /// The row is handed over and nothing else happens: the panel does not
    /// know that a documentation card exists, only that the reader asked about
    /// this row. Leaving it nil is what keeps the glyph off the row entirely —
    /// an affordance for a gesture nobody is listening for is a button that
    /// does nothing.
    var onInfoClicked: ((CodeCompletionItem) -> Void)?

    /// Whether a row has documentation worth opening.
    ///
    /// **A question asked of the host rather than of the item**, and that is
    /// the whole design of this property. `documentation != nil` cannot be the
    /// test: for most servers a row's prose only exists after a second
    /// request, so at the moment the row is drawn the honest answer is "the
    /// server said it can be asked" — which is a fact about the *server*, and
    /// the engine is not allowed to know that asking is a thing. The host
    /// knows all three inputs (whether resolve is supported, whether this row
    /// has a token to resolve, whether an answer already came back) and
    /// collapses them into a yes or a no here.
    ///
    /// Nil is the same as "no", for the reason above: a host that has not
    /// wired this has not wired the card either.
    var offersDocumentation: ((CodeCompletionItem) -> Bool)?

    /// The font the icon column's glyphs are drawn in, when the host has one.
    ///
    /// **Nil is a working list, not a broken one.** The engine cannot reach
    /// `Bundle.main` to find a bundled font — it takes what it needs as values
    /// — so this arrives from the host, and the host can only supply it if the
    /// resource registered. Every kind therefore keeps a complete
    /// `symbolName`, and this being nil falls back to it: a failed
    /// registration costs the list its Codicons and nothing else.
    ///
    /// **The size it arrives at does not matter** — the list resizes it to the
    /// editor's own point size on every fill, so the host sets this once and
    /// never has to hear about a font change. Handing over a fixed size and
    /// drawing it verbatim is the bug where the icons stay at thirteen point
    /// after the reader moves the editor to eighteen.
    var iconFont: NSFont?

    private(set) var items: [CodeCompletionItem] = []
    private(set) var selectedIndex = -1

    /// Whether the list is showing anything.
    ///
    /// Derived from the items rather than from `isVisible`, deliberately: the
    /// window's own visibility only becomes true by asking the window server to
    /// display it, so a property answered from the panel's own state is one a
    /// test can read without the hazard described in the class comment.
    var isOpen: Bool { !items.isEmpty }

    var selectedItem: CodeCompletionItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 4
    private let iconGap: CGFloat = 6
    private let detailGap: CGFloat = 12

    private let card = CardView()
    private let scrollView = NSScrollView()
    private let tableView = ListTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))

    private var query = ""
    private var theme = CodeTheme.fallback
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var anchor = NSRect.zero

    /// `iconFont` at the editor's point size, worked out once per fill rather
    /// than once per row — a server's answer runs to hundreds of rows and they
    /// are all drawn in the same font.
    private var scaledIconFont: NSFont?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow

        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autoresizingMask = [.width]

        tableView.selectionHighlightStyle = .none
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        card.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: verticalInset),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -verticalInset),
        ])

        contentView = card
    }

    /// Never key, never main — see the class comment. This is the property the
    /// whole design rests on, and it takes no argument and answers no question:
    /// there is no condition under which this window should hold focus.
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    // MARK: - Metrics

    /// Tall enough for a descender and a gap, in the editor's own font, so the
    /// list's rhythm matches the file's.
    static func rowHeight(for font: NSFont) -> CGFloat {
        ceil(font.pointSize * 1.6)
    }

    /// How many rows the window shows before it starts scrolling.
    static func visibleRowCount(of total: Int) -> Int {
        min(max(total, 0), maximumVisibleRows)
    }

    /// The window's content size for a list of `rowCount` rows.
    static func contentSize(rowCount: Int, width: CGFloat, rowHeight: CGFloat, inset: CGFloat) -> NSSize {
        NSSize(
            width: width,
            height: CGFloat(visibleRowCount(of: rowCount)) * rowHeight + inset * 2
        )
    }

    /// The width the widest of the first `measurementSampleSize` rows needs,
    /// clamped into `[minimumWidth, maximumWidth]`.
    ///
    /// Clamped rather than fitted because both ends are failures: a list
    /// narrower than `minimumWidth` flickers wider as soon as a longer label
    /// arrives, and one that grows past `maximumWidth` stops being a list beside
    /// the code and becomes a second window over it.
    static func measuredWidth(for items: [CodeCompletionItem], font: NSFont, chrome: CGFloat) -> CGFloat {
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: detailFont(for: font)]

        var widest: CGFloat = 0
        for item in items.prefix(measurementSampleSize) {
            var width = (item.label as NSString).size(withAttributes: labelAttributes).width
            if let detail = item.detail, !detail.isEmpty {
                width += (detail as NSString).size(withAttributes: detailAttributes).width
            }
            widest = max(widest, width)
        }
        return min(max(ceil(widest) + chrome, minimumWidth), maximumWidth)
    }

    /// A point smaller than the label's, because the detail is the column you
    /// read second.
    static func detailFont(for font: NSFont) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: max(font.pointSize - 1, 8), weight: .regular)
    }

    /// The row a click at `y` landed on, `y` measured downwards from the top of
    /// the list.
    ///
    /// Index arithmetic rather than `NSTableView.row(at:)` so it can be tested:
    /// driving a real click means `mouseDown`, whose superclass implementation
    /// runs an event-tracking loop waiting for a mouse-up that never comes
    /// outside a live window.
    static func rowIndex(atY y: CGFloat, rowHeight: CGFloat, count: Int) -> Int? {
        guard rowHeight > 0, count > 0, y >= 0 else { return nil }
        let index = Int(floor(y / rowHeight))
        return index < count ? index : nil
    }

    /// Where the selection lands after a movement key.
    ///
    /// Up and down **wrap**, because the list is a ring you steer with rather
    /// than a document you scroll: pressing down at the last row to get back to
    /// the first is what every completion list does, and stopping dead there
    /// reads as a broken key. Page movements clamp instead — a page is a
    /// distance, and wrapping a distance would land somewhere unrelated to where
    /// the eye was.
    ///
    /// An empty list answers `-1`, which is `NSTableView`'s own "no row" and the
    /// value `selectedItem` reads as nil.
    static func selection(_ movement: Movement, from current: Int, count: Int, pageSize: Int) -> Int {
        guard count > 0 else { return -1 }
        let page = max(1, pageSize)
        let index = min(max(current, 0), count - 1)

        switch movement {
        case .up: return index == 0 ? count - 1 : index - 1
        case .down: return index == count - 1 ? 0 : index + 1
        case .pageUp: return max(0, index - page)
        case .pageDown: return min(count - 1, index + page)
        case .first: return 0
        case .last: return count - 1
        }
    }

    /// The row highlighted when a list is first shown.
    ///
    /// The server's preselection when it asked for one, the top row otherwise.
    /// A server only sets it where it knows something the ranking cannot — the
    /// type expected at this position, most often — so honouring it costs a
    /// line and is the difference between the right row being one keystroke
    /// away and being six.
    static func initialSelection(in items: [CodeCompletionItem]) -> Int {
        guard !items.isEmpty else { return -1 }
        return items.firstIndex(where: \.isPreselected) ?? 0
    }

    /// The characters of `item.label` the query matched, for bolding.
    ///
    /// Empty when the server gave a `filterText` that differs from the label,
    /// and that guard is the whole reason this is a function rather than a call
    /// to the filter at the draw site. The filter's ranges are offsets into
    /// whatever it matched, which is `filterText ?? label`; TypeScript offers an
    /// optional member as `label: "foo?"` with `filterText: "foo"`, so applying
    /// those offsets to the label is drawing emphasis on the wrong characters —
    /// silently, and only for the rows where the label matters most.
    static func highlightRanges(query: String, item: CodeCompletionItem) -> [NSRange] {
        guard item.matchText == item.label else { return [] }
        return CodeCompletionFilter.match(query: query, candidate: item.label)?.ranges ?? []
    }

    /// The icon column's glyph, in the colour the highlighter would paint this
    /// identifier if it were already in the file.
    ///
    /// Both halves come from `CodeCompletionItem.Kind` — `symbolName` and
    /// `tokenKind` — rather than from a mapping of this file's own, so the icon
    /// beside a call is the colour the call is drawn in two lines up.
    static func icon(for kind: CodeCompletionItem.Kind, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image.withSymbolConfiguration(configuration)
    }

    /// The same icon as a glyph out of the Codicons font, for the path where
    /// the host supplied one.
    ///
    /// Centred in its column rather than drawn from the left, because a
    /// Codicon is a character in a font sized for a UI and its advance width
    /// is nothing to do with the square the SF Symbol occupied — left-aligning
    /// the two paths puts the label in a different place depending on whether
    /// a font registered.
    ///
    /// The colour is applied here and not left to the drawing site for the
    /// reason the icon exists at all: it is `Kind.tokenKind` resolved against
    /// the theme, so a glyph without it is the one thing worse than an SF
    /// Symbol — the right shape in the wrong colour.
    /// The icon font at the size the rows are drawn in.
    ///
    /// Nil in, nil out, which is the SF Symbol path. A descriptor that will not
    /// round-trip back through `NSFont` returns the original rather than
    /// nothing — the wrong size is a smaller failure than a blank column, and
    /// it is the same defensive shape `bold(_:)` above already takes.
    static func scaled(_ font: NSFont?, to pointSize: CGFloat) -> NSFont? {
        guard let font else { return nil }
        guard font.pointSize != pointSize else { return font }
        return NSFont(descriptor: font.fontDescriptor, size: pointSize) ?? font
    }

    static func iconGlyph(
        for kind: CodeCompletionItem.Kind,
        color: NSColor,
        font: NSFont
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        return NSAttributedString(string: String(kind.codicon), attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// The colour the row's text is drawn in.
    ///
    /// The same colour as the icon, by request: a list where the whole row
    /// carries the kind's colour reads as a list of *things* rather than a
    /// list of words with a decorated margin.
    ///
    /// **This one function is the switch.** Returning
    /// `theme.foreground` here puts every label back to the reader's plain
    /// text colour and leaves the icons coloured, which is the other design
    /// worth trying; nothing else in this file has to change, because nothing
    /// else asks what colour a label is.
    static func labelColor(for item: CodeCompletionItem, theme: CodeTheme) -> NSColor {
        theme.color(for: item.kind.tokenKind)
    }

    /// The band drawn behind the highlighted row.
    ///
    /// Drawn from the theme's foreground rather than taken from `NSTableView`'s
    /// own selection, because this window is never key: AppKit would paint the
    /// inactive grey it reserves for a background window, permanently, and the
    /// one row the reader is steering with would be the hardest one to see. A
    /// translucent wash of the foreground is the one colour guaranteed to
    /// contrast with the background in every theme a host can hand over.
    static func selectionColor(for theme: CodeTheme) -> NSColor {
        theme.foreground.withAlphaComponent(0.16)
    }

    /// `[icon] label ·········· detail`, with the matched characters emboldened.
    static func labelText(
        for item: CodeCompletionItem,
        query: String,
        theme: CodeTheme,
        font: NSFont
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let color = labelColor(for: item, theme: theme)
        let result = NSMutableAttributedString(string: item.label, attributes: [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.9),
            .paragraphStyle: paragraph,
        ])

        let bold = Self.bold(font)
        let full = NSRange(location: 0, length: result.length)
        for range in highlightRanges(query: query, item: item) where NSIntersectionRange(range, full) == range {
            result.addAttributes([.font: bold, .foregroundColor: color], range: range)
        }
        return result
    }

    // MARK: - The info affordance

    /// Whether the highlighted row shows its info glyph.
    ///
    /// Only the selected row, and only when there is something behind the
    /// glyph. Both halves are load-bearing and for different reasons: a column
    /// of info glyphs down every row is a second icon column competing with
    /// the first for the same glance, and a glyph on a row with nothing to say
    /// is a button that answers "no documentation" — which the reader could
    /// have been told by its absence, for free.
    static func showsInfo(isSelected: Bool, hasDocumentation: Bool) -> Bool {
        isSelected && hasDocumentation
    }

    /// The glyph's square, at the row's trailing edge.
    ///
    /// Reserved on *every* row rather than only the selected one — see
    /// `reservesInfoColumn` — so the detail column does not shuffle sideways
    /// as the selection moves down a list the reader is steering with.
    static func infoRect(in bounds: NSRect, side: CGFloat, inset: CGFloat) -> NSRect {
        NSRect(
            x: bounds.maxX - inset - side,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    /// The `ⓘ` itself, from the Codicons font when there is one and from SF
    /// Symbols otherwise — the same fallback the kind icons take, and for the
    /// same reason.
    ///
    /// Dimmer than the row it sits on. It is an offer rather than a statement:
    /// at full strength it would be the brightest thing on the selected row,
    /// which is the row whose *label* is the thing being read.
    static func infoGlyph(theme: CodeTheme, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        return NSAttributedString(string: "\u{EA74}", attributes: [
            .font: font,
            .foregroundColor: theme.foreground.withAlphaComponent(0.55),
            .paragraphStyle: paragraph,
        ])
    }

    static func infoImage(theme: CodeTheme, pointSize: CGFloat) -> NSImage? {
        guard let image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Documentation") else {
            return nil
        }
        let color = theme.foreground.withAlphaComponent(0.55)
        return image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        )
    }

    /// A bolder cut of the editor's own font, falling back to the system
    /// monospace at the same size.
    ///
    /// The fallback is not decoration: a descriptor carrying the system UI
    /// font's traits does not always round-trip back through `NSFont`, and
    /// returning the original font there would leave the matched characters
    /// looking exactly like the rest — which is the one thing this drawing pass
    /// is for.
    static func bold(_ font: NSFont) -> NSFont {
        if let bolder = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: font.pointSize),
           bolder != font {
            return bolder
        }
        return .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
    }

    /// The right-hand column: dimmed, and truncated from the head rather than
    /// the tail.
    ///
    /// Head truncation because a detail is a qualified name — `react/index`,
    /// `Array<T>.concat` — whose distinguishing half is at the *end*. Cutting
    /// the tail leaves six rows all reading `Array<T>.con…`, which is the
    /// problem the detail column exists to solve.
    static func detailText(_ detail: String, theme: CodeTheme, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        paragraph.alignment = .right

        return NSAttributedString(string: detail, attributes: [
            .font: detailFont(for: font),
            .foregroundColor: theme.foreground.withAlphaComponent(0.5),
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Presenting

    /// Fills the list and puts it under `anchor`, given in screen coordinates.
    ///
    /// `anchor` is the **start of the prefix**, not the caret: the list is about
    /// the word being typed, so it lines up with the word's first character and
    /// stays put as the word grows. A zero-height anchor means the caller could
    /// not work out where that was, and a list pinned to the bottom-left corner
    /// of the screen is worse than no list.
    ///
    /// An empty list dismisses instead of presenting, which is also what lets a
    /// test call this: the guard returns before `orderFront`, and asking the
    /// window server to show a window from a host with no event loop hangs
    /// forever rather than failing.
    func present(
        _ items: [CodeCompletionItem],
        query: String,
        theme: CodeTheme,
        font: NSFont,
        anchor: NSRect,
        over view: NSView
    ) {
        guard !items.isEmpty, anchor.height > 0, let parentWindow = view.window else {
            dismiss()
            return
        }

        self.theme = theme
        self.font = font
        self.anchor = anchor

        fill(items, query: query)
        resize()
        position(on: parentWindow.screen ?? NSScreen.main)

        if parent == nil { parentWindow.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        invalidateShadow()
    }

    /// Replaces the rows without moving the list, for the next keystroke's
    /// refinement.
    ///
    /// The window keeps its origin on purpose: the anchor is the prefix's start
    /// and typing does not move it, so re-placing the panel per character would
    /// make it jitter under a hand that is still typing.
    func update(_ items: [CodeCompletionItem], query: String) {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        fill(items, query: query)
        resize()
    }

    func dismiss() {
        let wasOpen = isOpen
        items = []
        selectedIndex = -1
        if wasOpen { onSelectionChange?(nil) }

        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    // MARK: - Selection

    func moveSelection(_ movement: Movement) {
        let next = Self.selection(
            movement,
            from: selectedIndex,
            count: items.count,
            pageSize: Self.visibleRowCount(of: items.count)
        )
        select(next)
    }

    /// Hands the highlighted row to the host. Nothing is inserted here — the
    /// panel does not know what a document is.
    func acceptSelection() {
        guard let item = selectedItem else { return }
        onAccept?(item)
    }

    private func select(_ index: Int) {
        guard index != selectedIndex else { return }
        let previous = selectedIndex
        selectedIndex = index

        if items.indices.contains(index) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        tableView.enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
        rebuildInfoAffordance(movingFrom: previous, to: index)
        onSelectionChange?(selectedItem)
    }

    /// Rebuilds the two rows whose info glyph changed.
    ///
    /// The band above is repainted by marking the row views dirty, and that is
    /// enough for it because the band is *drawn*. The glyph is not — it is
    /// content, handed to the cell in `tableView(_:viewFor:row:)`, which
    /// nothing re-runs when the selection moves. Two rows rather than a
    /// `reloadData`, because this is the arrow key's path and the list behind
    /// it can be several hundred rows long.
    private func rebuildInfoAffordance(movingFrom previous: Int, to index: Int) {
        guard reservesInfoColumn else { return }

        let rows = IndexSet([previous, index].filter(items.indices.contains))
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        select(row)
        acceptSelection()
    }

    // MARK: - Content

    private func fill(_ items: [CodeCompletionItem], query: String) {
        self.items = items
        self.query = query
        scaledIconFont = Self.scaled(iconFont, to: font.pointSize)

        let background = theme.background.withAlphaComponent(1)
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderColor = theme.foreground.withAlphaComponent(0.18).cgColor

        tableView.rowHeight = Self.rowHeight(for: font)
        tableView.reloadData()

        selectedIndex = -1
        select(Self.initialSelection(in: items))
    }

    /// The chrome a row needs beyond its text: the icon column, the gaps either
    /// side of it, the gap before the detail and the room an overlay scroller
    /// takes when it appears — plus the info column when the host asked for
    /// one, which is measured here so a list with the affordance is a little
    /// wider rather than a little more truncated.
    private var chromeWidth: CGFloat {
        horizontalInset * 2 + iconSide + iconGap + detailGap + 12
            + (reservesInfoColumn ? iconSide + iconGap : 0)
    }

    private var iconSide: CGFloat { ceil(font.pointSize * 1.15) }

    /// Whether every row leaves room at its trailing edge for an info glyph.
    ///
    /// A property of the *list* and not of the row, deliberately. The glyph
    /// appears on one row at a time, and reserving its width only on that row
    /// would slide the detail column left and right as the selection moves —
    /// under a hand that is holding the down arrow, which is the worst
    /// possible moment for the list to reflow.
    private var reservesInfoColumn: Bool {
        onInfoClicked != nil && offersDocumentation != nil
    }

    private func resize() {
        let width = Self.measuredWidth(for: items, font: font, chrome: chromeWidth)
        let size = Self.contentSize(
            rowCount: items.count,
            width: width,
            rowHeight: Self.rowHeight(for: font),
            inset: verticalInset
        )
        setContentSize(size)

        card.layoutSubtreeIfNeeded()
        column.width = scrollView.contentSize.width
    }

    private func position(on screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: frame.size)
        setFrameOrigin(PanelPlacement.origin(
            anchor: anchor,
            size: frame.size,
            visible: visible,
            prefers: .below
        ))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.rowHeight(for: font)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: RowView.reuseIdentifier, owner: nil) as? RowView
            ?? RowView(identifier: RowView.reuseIdentifier)

        view.selectionColor = Self.selectionColor(for: theme)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]

        let cell = tableView.makeView(withIdentifier: RowCellView.reuseIdentifier, owner: nil) as? RowCellView
            ?? RowCellView(identifier: RowCellView.reuseIdentifier)

        cell.horizontalInset = horizontalInset
        cell.iconSide = iconSide
        cell.iconGap = iconGap
        cell.detailGap = detailGap

        let color = theme.color(for: item.kind.tokenKind)
        if let scaledIconFont {
            cell.icon = nil
            cell.iconText = Self.iconGlyph(for: item.kind, color: color, font: scaledIconFont)
        } else {
            cell.icon = Self.icon(for: item.kind, color: color, pointSize: font.pointSize)
            cell.iconText = nil
        }

        cell.label = Self.labelText(for: item, query: query, theme: theme, font: font)
        cell.detail = item.detail.flatMap { detail in
            detail.isEmpty ? nil : Self.detailText(detail, theme: theme, font: font)
        }

        cell.reservesInfoColumn = reservesInfoColumn
        let showsInfo = Self.showsInfo(
            isSelected: row == selectedIndex,
            hasDocumentation: reservesInfoColumn && (offersDocumentation?(item) ?? false)
        )
        cell.info = showsInfo ? infoAffordance() : nil
        cell.onInfoClicked = showsInfo ? { [weak self] in self?.onInfoClicked?(item) } : nil

        cell.needsDisplay = true
        return cell
    }

    /// The info glyph as the row should draw it, taking the same font fallback
    /// the kind icons take.
    private func infoAffordance() -> RowCellView.Info {
        if let scaledIconFont {
            return .glyph(Self.infoGlyph(theme: theme, font: scaledIconFont))
        }
        return .image(Self.infoImage(theme: theme, pointSize: font.pointSize))
    }

    /// A click on a row selects it, and nothing else does.
    ///
    /// In particular **hovering does not move the selection**: no tracking area
    /// is installed anywhere in this hierarchy, so the pointer crossing the list
    /// on its way somewhere else cannot change which row the next Return would
    /// accept. That is a real hazard rather than a theoretical one — the list
    /// opens under the caret, which is wherever the hand happens to have left
    /// the pointer.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // MARK: - Views

    /// The list's background, and the thing that rounds its corners.
    private final class CardView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A table that never wants focus.
    ///
    /// `refusesFirstResponder` rather than an override, because the goal is not
    /// to make the table awkward to focus but to stop it asking: the panel it
    /// lives in cannot become key, so a table that keeps requesting first
    /// responder is asking a window that will always say no.
    private final class ListTableView: NSTableView {
        /// Without this the first click on a row in a panel that is not key is
        /// swallowed as an activation click, and every row needs two clicks —
        /// permanently, since this panel is never key by design.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// The selection band.
    ///
    /// Drawn here rather than by `NSTableView` because the table's own selection
    /// is `.none` — see `selectionColor(for:)` for why.
    private final class RowView: NSTableRowView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("CodeCompletionRowBackground")

        var selectionColor: NSColor = .clear

        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            self.identifier = identifier
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// `NSTableRowView` only redraws itself on a selection change when it is
        /// drawing the selection, and here it is not — the table's own style is
        /// `.none`. Without this the band is painted where the selection was
        /// when the row was last drawn.
        override var isSelected: Bool {
            didSet { needsDisplay = true }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected else { return }
            selectionColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 3, dy: 0),
                xRadius: 4,
                yRadius: 4
            ).fill()
        }
    }

    /// One row: icon, label, and a right-aligned detail.
    ///
    /// Drawn rather than laid out. A stack of labels per row is three views and
    /// an autolayout pass each, and a server's answer routinely runs to hundreds
    /// of rows that are recycled on every keystroke.
    private final class RowCellView: NSView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("CodeCompletionRow")

        /// Whichever of the two the host's font situation allows, so the
        /// affordance is one thing to the row rather than two nullable ones.
        enum Info {
            case image(NSImage?)
            case glyph(NSAttributedString)
        }

        var icon: NSImage?

        /// The icon as a Codicon. Mutually exclusive with `icon` — the panel
        /// sets exactly one of them, according to whether a font registered.
        var iconText: NSAttributedString?

        var label: NSAttributedString?
        var detail: NSAttributedString?
        var horizontalInset: CGFloat = 8
        var iconSide: CGFloat = 14
        var iconGap: CGFloat = 6
        var detailGap: CGFloat = 12

        /// Whether to keep the trailing square clear even on rows that are not
        /// showing the glyph. See `CodeCompletionPanel.reservesInfoColumn`.
        var reservesInfoColumn = false

        var info: Info? {
            didSet {
                button.info = info
                button.isHidden = info == nil
                needsLayout = true
            }
        }

        var onInfoClicked: (() -> Void)? {
            didSet { button.onClick = onInfoClicked }
        }

        private let button = InfoButton()

        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            self.identifier = identifier
            button.isHidden = true
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func layout() {
            super.layout()
            button.frame = CodeCompletionPanel.infoRect(
                in: bounds,
                side: iconSide,
                inset: horizontalInset
            )
        }

        /// The width the trailing edge gives up, which is a constant of the
        /// list rather than of this row — the glyph moving between rows must
        /// not move the detail column with it.
        private var infoColumnWidth: CGFloat {
            reservesInfoColumn ? iconSide + iconGap : 0
        }

        /// The detail never takes more than half the row, so a long qualified
        /// name cannot squeeze the label — which is the column being read — down
        /// to an ellipsis.
        override func draw(_ dirtyRect: NSRect) {
            let iconRect = NSRect(
                x: horizontalInset,
                y: (bounds.height - iconSide) / 2,
                width: iconSide,
                height: iconSide
            )
            if let iconText {
                draw(iconText, in: iconRect)
            } else {
                icon?.draw(in: iconRect)
            }

            let textLeft = iconRect.maxX + iconGap
            let right = bounds.maxX - horizontalInset - infoColumnWidth
            let available = max(right - textLeft, 0)

            var detailWidth: CGFloat = 0
            if let detail {
                detailWidth = min(ceil(detail.size().width), available / 2)
                let rect = NSRect(
                    x: right - detailWidth,
                    y: textBaseline(for: detail),
                    width: detailWidth,
                    height: detail.size().height
                )
                detail.draw(with: rect, options: [.usesLineFragmentOrigin])
            }

            guard let label else { return }
            let labelWidth = max(available - (detailWidth > 0 ? detailWidth + detailGap : 0), 0)
            label.draw(
                with: NSRect(
                    x: textLeft,
                    y: textBaseline(for: label),
                    width: labelWidth,
                    height: label.size().height
                ),
                options: [.usesLineFragmentOrigin]
            )
        }

        /// Centred vertically in the square the SF Symbol would have filled, so
        /// the two icon paths sit on the same line as each other and as the
        /// label.
        private func draw(_ glyph: NSAttributedString, in square: NSRect) {
            let height = glyph.size().height
            glyph.draw(
                with: NSRect(
                    x: square.minX,
                    y: square.midY - height / 2,
                    width: square.width,
                    height: height
                ),
                options: [.usesLineFragmentOrigin]
            )
        }

        private func textBaseline(for text: NSAttributedString) -> CGFloat {
            (bounds.height - text.size().height) / 2
        }
    }

    /// The `ⓘ` on the highlighted row.
    ///
    /// A view of its own rather than a rectangle the row hit-tests, because the
    /// row's click already means something: `tableView.action` accepts the
    /// completion. A subview that consumes `mouseDown` and does not call super
    /// is what stops the table ever hearing the click, so asking about a row
    /// cannot insert it by accident.
    private final class InfoButton: NSView {
        var info: RowCellView.Info? {
            didSet { needsDisplay = true }
        }

        var onClick: (() -> Void)?

        override var isFlipped: Bool { true }

        /// Without this the first click is spent activating a panel that can
        /// never be key — see `ListTableView`, which needs it for the rows and
        /// gets no say over a subview of its own cells.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func draw(_ dirtyRect: NSRect) {
            switch info {
            case .image(let image):
                image?.draw(in: bounds)
            case .glyph(let glyph):
                let height = glyph.size().height
                glyph.draw(
                    with: NSRect(
                        x: bounds.minX,
                        y: bounds.midY - height / 2,
                        width: bounds.width,
                        height: height
                    ),
                    options: [.usesLineFragmentOrigin]
                )
            case nil:
                return
            }
        }
    }
}
