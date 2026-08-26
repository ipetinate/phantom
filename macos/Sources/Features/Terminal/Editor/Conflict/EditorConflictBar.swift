import AppKit

/// The row of choices over one conflict.
///
/// A plain `NSView` of `NSButton`s, added as a subview of the text view rather
/// than drawn by it. Being a subview of the document is what makes it scroll
/// with the text for free: the clip view scrolls by moving its bounds, so a
/// bar pinned to a line stays on that line without anybody observing a scroll.
///
/// It covers the `<<<<<<<` line completely, opaquely, and carries that line's
/// own words on its right.
///
/// Laid over the line while letting it show through, the two collided —
/// "Accept Current" printed across "<<<<<<< HEAD" is unreadable twice over.
/// Every other merge tool puts these choices on a line of their own above the
/// block, which is not available here: a line of their own means text in the
/// document, and this must not write into the reader's file to draw a control.
///
/// So the marker line becomes the row. Nothing is lost by it — the only thing
/// that line said was `<<<<<<<` and a branch name, and the branch name is on
/// the bar.
final class EditorConflictBar: NSView {
    /// Which conflict this belongs to, by position in the file. Not an index
    /// into anything: the bars are rebuilt whenever the text moves.
    let conflictID: Int

    private let onChoose: (EditorConflict.Choice) -> Void

    /// The branch `HEAD` is on, when the app knows it.
    ///
    /// Git writes `HEAD` into the marker rather than the branch name, which is
    /// accurate and tells a reader nothing they did not already know. The name
    /// comes from the status the sidebar already has.
    private let currentBranch: String?

    init(
        conflict: EditorConflict,
        font: NSFont,
        palette: EditorConflictBandsView.Palette?,
        currentBranch: String?,
        onChoose: @escaping (EditorConflict.Choice) -> Void
    ) {
        self.currentBranch = currentBranch
        self.conflictID = conflict.id
        self.onChoose = onChoose
        super.init(frame: .zero)

        /// Opaque, because it is covering text. A translucent bar over a line
        /// of code is the collision this exists to end.
        wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for choice in conflict.choices {
            stack.addArrangedSubview(
                button(for: choice, font: font, in: conflict, palette: palette))
        }

        /// What the covered line said. Dimmed and last, because it is context
        /// rather than a choice — and it is the answer to "current of what".
        let label = NSTextField(labelWithString: labelText(for: conflict))
        label.font = .systemFont(ofSize: max(9, min(11, font.pointSize - 3)))
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Where the buttons start.
    ///
    /// Aligned with the code rather than with the view's edge: the row is the
    /// full width of the text view, and buttons beginning at zero would start
    /// under the line numbers, left of every line of code around them.
    static let leadingInset: CGFloat = 60

    /// Which side is which, in the words git wrote into the file.
    ///
    /// `HEAD` is not translated to anything friendlier: it is what the file
    /// says and what every other git tool calls it, and a reader comparing
    /// this against `git status` should find the same word.
    private func labelText(for conflict: EditorConflict) -> String {
        let current = named(conflict.currentLabel, fallback: "current")
        let incoming = named(conflict.incomingLabel, fallback: "incoming")
        return "\(current) \u{2190} \(incoming)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func button(
        for choice: EditorConflict.Choice,
        font: NSFont,
        in conflict: EditorConflict,
        palette: EditorConflictBandsView.Palette?
    ) -> NSButton {
        let button = NSButton(title: choice.title, target: self, action: #selector(chose(_:)))
        button.toolTip = tooltip(for: choice, in: conflict)
        button.bezelStyle = .accessoryBarAction
        /// Mini rather than small, because the row this sits in is one line of
        /// code tall — around 22 points at the default size — and a small
        /// button fills it edge to edge with nothing left for margin.
        button.controlSize = .mini
        button.font = .systemFont(ofSize: max(9, min(11, font.pointSize - 3)))
        button.identifier = NSUserInterfaceItemIdentifier(choice.rawValue)
        button.setContentHuggingPriority(.required, for: .horizontal)

        /// Painted with the colour of the lines it keeps, so which button
        /// produces which text is answered by looking rather than by reading.
        /// `both` keeps two colours and takes neither.
        if let tint = palette?.color(for: choice) { button.bezelColor = tint }

        return button
    }

    /// Which side each button keeps, named.
    ///
    /// The titles say "Current" and "Incoming" because those are short enough
    /// for a row over a line of code and because they are the words git and
    /// every merge tool use. They are also relative, and a reader three
    /// conflicts deep has stopped tracking which branch is which — so the
    /// branch itself is one hover away rather than absent.
    private func tooltip(for choice: EditorConflict.Choice, in conflict: EditorConflict) -> String {
        let current = named(conflict.currentLabel, fallback: "the current branch")
        let incoming = named(conflict.incomingLabel, fallback: "the incoming branch")

        switch choice {
        case .current: return "Keep the version from \(current)"
        case .incoming: return "Keep the version from \(incoming)"
        case .both: return "Keep both, \(current) first"
        case .base: return "Keep what both branches started from"
        }
    }

    /// A marker's label, with the branch behind `HEAD` spelled out.
    ///
    /// `HEAD (main)` rather than either alone: `HEAD` is what the file says and
    /// what a reader comparing this against `git status` will find, and the
    /// name in brackets is the thing they actually recognise. Only for `HEAD`,
    /// since every other label already is a name.
    private func named(_ label: String, fallback: String) -> String {
        guard !label.isEmpty else { return fallback }
        guard label == "HEAD", let currentBranch, !currentBranch.isEmpty else { return label }
        return "HEAD (\(currentBranch))"
    }

    @objc private func chose(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let choice = EditorConflict.Choice(rawValue: raw)
        else { return }
        onChoose(choice)
    }

    /// A hairline under the row, so the block reads as starting here rather
    /// than as a coloured line that happens to have buttons on it.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let rule = separatorColor else { return }
        rule.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private var separatorColor: NSColor?

    func paint(_ color: NSColor, separator: NSColor) {
        layer?.backgroundColor = color.cgColor
        separatorColor = separator
        needsDisplay = true
    }

    /// The pointer over this is an arrow, not an I-beam.
    ///
    /// A subview of a text view inherits the text view's idea of the cursor,
    /// which is the I-beam over its whole area — so a row of buttons drawn
    /// inside one reads as text to point at. Both halves are needed: the rect
    /// covers the ordinary case, and `cursorUpdate` covers the moment the
    /// pointer arrives while the text view is rebuilding its own rects, which
    /// is exactly when a resolution has just moved everything.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// How wide the buttons and the label want to be. The caller gives the
    /// bar the whole row regardless — it is covering a line — and this is
    /// what it uses to know whether the label fits.
    var preferredSize: NSSize { fittingSize }
}
