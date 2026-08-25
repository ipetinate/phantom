import AppKit

/// The line-number column.
///
/// A view **beside** the text, not on top of it. An `NSRulerView` shares
/// the scroll view's area and leaves it to the ruler to stay out of the
/// text's way — which it does not reliably do once the ruler draws its own
/// background, and the numbers ended up printed over the first characters
/// of every line. Two views side by side cannot overlap by construction:
/// the text starts where this ends, and the scroll view clips its own
/// content the way it always did.
///
/// It is drawn as one view rather than a label per line, which is the only
/// shape that survives a large file — a hundred thousand subviews is a
/// hundred thousand things to lay out, and forty of them are visible.
///
/// It also carries one ``Mark``, at the leading edge of a single line: the
/// margin is where "this line, this one" belongs, and it is the only place in
/// the editor that can say it without covering the code. The column that mark
/// sits in is reserved on every file whether or not anything is in it, because
/// this view's width is where the text starts.
final class CodeGutterView: NSView {
    var theme: CodeTheme {
        didSet { needsDisplay = true }
    }

    var font: NSFont {
        didSet {
            invalidateWidth()
            needsDisplay = true
        }
    }

    /// Top-left origin, like the text view it sits beside.
    ///
    /// `NSView` is bottom-left by default while `NSTextView` is flipped, so
    /// without this the two disagree about which way `y` grows — and the
    /// line numbers came out counting *down* the file, ending at 1 on the
    /// last visible row.
    override var isFlipped: Bool { true }

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    /// The width the numbers need, which grows once when a file passes a
    /// thousand lines instead of clipping.
    private(set) var preferredWidth: CGFloat = 40

    var onWidthChange: ((CGFloat) -> Void)?

    /// A mark in the margin of one line, drawn at the leading edge.
    ///
    /// Pixels and a number, and nothing that knows what an agent is:
    /// everything under `Engine/` stays ignorant of the app, and an `NSImage`
    /// is also the only shape that keeps ``draw(_:)`` free of work — see
    /// `EditorAgentMarkImages`, which renders and caches it.
    ///
    /// `Equatable` by image identity, which is exactly right here: the cache
    /// hands back the same object for the same agent and size, so an unchanged
    /// mark compares equal and ``setMark(_:)`` costs nothing.
    struct Mark: Equatable {
        let line: Int
        let image: NSImage
    }

    private var mark: Mark?

    init(textView: NSTextView, scrollView: NSScrollView, theme: CodeTheme, font: NSFont) {
        self.theme = theme
        self.font = font
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)

        // Redrawn as the text scrolls: this view doesn't move with the
        // content, so it has to repaint with the new first visible line.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrolled() {
        needsDisplay = true
    }

    /// The line the cursor is on, drawn in the theme's brighter colour.
    ///
    /// The other half of the current-line highlight: the band marks where you
    /// are in the text, the number marks it in the margin. Both colours were
    /// already in the theme with nothing reading them.
    private var currentLine: Int?

    func setCurrentLine(_ line: Int?) {
        guard line != currentLine else { return }
        currentLine = line
        needsDisplay = true
    }

    /// Hangs a mark on one line, or takes the last one down.
    ///
    /// The width is deliberately not touched: the column the mark sits in is
    /// reserved whether or not there is anything in it. See
    /// ``markColumnWidth(for:)``.
    ///
    /// A reader who has turned the line numbers off has turned this off with
    /// them — the whole view is hidden and its width is zero. That is the right
    /// answer rather than a gap: a mark with no number beside it names a line
    /// the reader cannot read back.
    func setMark(_ mark: Mark?) {
        guard mark != self.mark else { return }
        self.mark = mark
        needsDisplay = true
    }

    func reload() {
        invalidateWidth()
        needsDisplay = true
    }

    private func invalidateWidth() {
        guard let textView else { return }
        let lines = max(1, textView.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        let width = Self.width(forLineCount: lines, font: font)

        guard width != preferredWidth else { return }
        preferredWidth = width
        onWidthChange?(width)
    }

    // MARK: The mark column

    /// How much room the widest number leaves to its right.
    static let numberTrailingInset: CGFloat = 8

    /// Where the mark starts, and how much clear space follows it before the
    /// numbers may begin.
    static let markLeadingInset: CGFloat = 3
    private static let markTrailingGap: CGFloat = 3

    /// How tall and wide a mark is drawn, given the gutter's font.
    ///
    /// Tied to the font rather than fixed, because the font is what sets the
    /// row height, and a mark that does not follow it is wrong at both ends of
    /// the range: lost in the tall rows of a large editor font, and taller than
    /// the row it belongs to in a small one. Nine-tenths of the point size keeps
    /// it a shade shorter than the digits beside it. The clamp is what stops the
    /// extremes of the font-size setting from carrying that ratio somewhere
    /// silly.
    ///
    /// The one number both halves of this feature have to agree on: the app
    /// renders the bitmap at this size and the gutter draws it at this size,
    /// and they agree because they both ask here.
    static func markSize(for font: NSFont) -> CGFloat {
        min(14, max(9, (font.pointSize * 0.9).rounded()))
    }

    /// The leading column a mark lives in, reserved whether or not one is set.
    ///
    /// Unconditional, and that is the decision rather than an oversight. A
    /// column that appeared with the first mark would change this view's width,
    /// and this view's width is where the text begins — so the whole document
    /// would reflow the moment an agent pointed at a line in it, which is a
    /// worse thing to do to a reader than to spend the room. The room is
    /// ``markSize(for:)`` minus 2pt of the padding that was already here: 9pt
    /// at the default 12pt editor font.
    static func markColumnWidth(for font: NSFont) -> CGFloat {
        markLeadingInset + markSize(for: font) + markTrailingGap
    }

    /// The width the numbers and the mark column need together.
    ///
    /// Static and pure, so the property that matters can be checked rather than
    /// merely read: it does not take a mark, so no mark can move it.
    static func width(forLineCount lines: Int, font: NSFont) -> CGFloat {
        let digits = String(max(1, lines)).count
        let sample = String(repeating: "8", count: max(3, digits)) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width)
            + markColumnWidth(for: font)
            + numberTrailingInset
    }

    /// Where a mark goes inside the row it belongs to, centred on it.
    static func markRect(in row: NSRect, size: CGFloat) -> NSRect {
        NSRect(
            x: markLeadingInset,
            y: row.minY + ((row.height - size) / 2).rounded(),
            width: size,
            height: size
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let scrollView
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.lineNumber,
        ]
        let currentAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.currentLineNumber,
        ]

        let visible = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let text = textView.string as NSString

        /// Measured once for the pass rather than per row. It is two
        /// multiplications, but this runs on every scroll notification and the
        /// rule for this view is that nothing per-row does arithmetic it can be
        /// handed instead.
        let markSize = Self.markSize(for: font)

        var lineNumber = 1

        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            let lines = Self.lineCount(
                in: text,
                range: Self.characterRange(of: fragment, in: contentManager)
            )

            guard frame.maxY + inset >= visible.minY else {
                lineNumber += lines
                return true
            }
            guard frame.minY + inset <= visible.maxY else { return false }

            // A file that ends in a newline shows one more line than it has
            // text for, and TextKit hands that empty line back *inside* the
            // last fragment rather than as one of its own — same frame, twice
            // the height. Numbering the fragment as a single row therefore
            // centred its number between the two, and left the last line of
            // every file in this repo with no number at all.
            let extra = Self.extraLineFragment(of: fragment)
            let split = Self.rowSplit(
                fragmentHeight: frame.height,
                extraLineHeight: extra?.typographicBounds.height ?? 0
            )
            let top = frame.minY + inset - visible.minY

            draw(number: lineNumber, in: NSRect(
                x: 0,
                y: top,
                width: bounds.width,
                height: split.numbered
            ), plain: attributes, current: currentAttributes, markSize: markSize)

            if let extra {
                draw(number: lineNumber + lines, in: NSRect(
                    x: 0,
                    y: top + split.extraOffset,
                    width: bounds.width,
                    height: extra.typographicBounds.height
                ), plain: attributes, current: currentAttributes, markSize: markSize)
            }

            lineNumber += lines
            return true
        }
    }

    /// Draws one number centred in the row it belongs to, and the mark beside
    /// it when this is the marked line.
    ///
    /// The two cannot overlap, and it is arithmetic rather than luck: the
    /// widest number a file can hold starts at exactly
    /// ``markColumnWidth(for:)`` — the width formula puts it there — and the
    /// mark ends ``markTrailingGap`` short of that. A narrower number starts
    /// further right still.
    private func draw(
        number: Int,
        in row: NSRect,
        plain: [NSAttributedString.Key: Any],
        current: [NSAttributedString.Key: Any],
        markSize: CGFloat
    ) {
        let label = String(number) as NSString
        let attributes = number == currentLine ? current : plain
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: bounds.width - size.width - Self.numberTrailingInset,
                y: row.minY + (row.height - size.height) / 2
            ),
            withAttributes: attributes
        )

        guard let mark, mark.line == number else { return }
        mark.image.draw(in: Self.markRect(in: row, size: markSize))
    }

    /// The empty line TextKit appends to a document that ends in a newline,
    /// or nil for every other fragment.
    ///
    /// Recognised by carrying no characters. A soft-wrapped line is also more
    /// than one line fragment, and its last one has text in it — which is what
    /// keeps wrapping out of this.
    private static func extraLineFragment(
        of fragment: NSTextLayoutFragment
    ) -> NSTextLineFragment? {
        let lines = fragment.textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0
        else { return nil }
        return last
    }

    /// How a fragment's height splits between the rows that carry a number of
    /// their own: the text, and the appended empty line when there is one.
    static func rowSplit(
        fragmentHeight: CGFloat,
        extraLineHeight: CGFloat
    ) -> (numbered: CGFloat, extraOffset: CGFloat) {
        let numbered = max(0, fragmentHeight - extraLineHeight)
        return (numbered: numbered, extraOffset: numbered)
    }

    private static func characterRange(
        of fragment: NSTextLayoutFragment,
        in contentManager: NSTextContentManager
    ) -> NSRange {
        let range = fragment.rangeInElement
        let location = contentManager.offset(
            from: contentManager.documentRange.location,
            to: range.location
        )
        let length = contentManager.offset(from: range.location, to: range.endLocation)
        return NSRange(location: location, length: length)
    }

    /// How many lines a fragment covers. A wrapped line is one fragment
    /// with no newline in it, so this returns zero and the number doesn't
    /// advance — which is what keeps the numbers aligned with the text
    /// rather than counting screen rows.
    private static func lineCount(in text: NSString, range: NSRange) -> Int {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard safe.length > 0 else { return 0 }

        var count = 0
        text.enumerateSubstrings(
            in: safe,
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
