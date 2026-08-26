import AppKit
@testable import Ghostty
import Testing

/// How wide the preview lets its prose run.
///
/// Two pure pieces and one view. The arithmetic is where the regressions will
/// be — a gutter computed from the wrong width is the difference between a
/// centred column and a document wedged against one edge — so it is asserted
/// without a window, and the view test only checks that the number reaches the
/// text container.
struct MarkdownPreviewWidthTests {
    private let base = MarkdownDocumentTextView.baseInset

    // MARK: - The gutters

    @Test func fluidKeepsTheBareEdgeInset() {
        #expect(MarkdownPreviewWidth.inset(paneWidth: 1_600, measure: nil, base: base) == base)
    }

    @Test func aWidePaneSplitsTheRemainderIntoTwoGutters() {
        let inset = MarkdownPreviewWidth.inset(paneWidth: 1_600, measure: 500, base: base)
        #expect(inset == 550)
        /// Which is what centres the column: the same inset on both sides
        /// leaves the text exactly in the middle.
        #expect(1_600 - inset * 2 == 500)
    }

    /// A pane with no room to give stays fluid. Splitting the remainder anyway
    /// would hand a 520-point pane a 10-point margin and a column of wrapped
    /// fragments, which is worse than the full width it already had.
    @Test func aPaneTooNarrowToGiveGuttersStaysFluid() {
        #expect(MarkdownPreviewWidth.inset(paneWidth: 520, measure: 500, base: base) == base)
        #expect(MarkdownPreviewWidth.inset(paneWidth: 400, measure: 500, base: base) == base)
    }

    /// The boundary, which is the case a split pane sits in: the gutters have
    /// to be worth more than the inset they replace before they are taken.
    @Test func theThresholdIsTwiceTheBaseInset() {
        #expect(MarkdownPreviewWidth.inset(paneWidth: 500 + base * 2, measure: 500, base: base) == base)
        #expect(MarkdownPreviewWidth.inset(paneWidth: 500 + base * 2 + 2, measure: 500, base: base) == base + 1)
    }

    @Test func aMeasureOfNothingIsNoMeasureAtAll() {
        #expect(MarkdownPreviewWidth.inset(paneWidth: 1_600, measure: 0, base: base) == base)
    }

    // MARK: - The measure

    /// Where the number comes from: 104 characters of the preview's own font,
    /// well past the 65-to-80 range prose is read at, because that range
    /// assumes a printed page and this is a wide pane.
    @Test func theMeasureHoldsAboutAHundredCharacters() {
        let font = MarkdownStyle.fallback.bodyFont
        let line = String(String(repeating: "abcdefghijklmnopqrstuvwxyz ", count: 5).prefix(104))
        let width = (line as NSString).size(withAttributes: [.font: font]).width
        let measure = MarkdownStyle.measure(for: font)

        #expect(width > measure * 0.9)
        #expect(width < measure * 1.1)
    }

    /// Derived rather than hardcoded, which is the whole reason it is measured:
    /// a reader who makes the editor's font bigger gets a wider column with the
    /// same number of characters on the line.
    @Test func aBiggerFontAsksForAWiderColumn() {
        let small = MarkdownStyle.measure(for: .systemFont(ofSize: 11))
        let large = MarkdownStyle.measure(for: .systemFont(ofSize: 22))
        #expect(large > small)
        #expect(small > 0)
    }

    /// An image is never wider than the prose it sits in.
    @Test func anImageIsHeldToTheMeasure() {
        #expect(MarkdownStyle.fallback.maxImageWidth == MarkdownStyle.fallback.measure)
    }

    // MARK: - The control

    /// The glyph and the words picture what pressing the control produces, not
    /// what is already on screen — the same bargain the split toggle makes.
    @Test func theControlPicturesWhatItWillProduce() {
        #expect(MarkdownPreviewWidth.fluid.toggled == .contained)
        #expect(MarkdownPreviewWidth.contained.toggled == .fluid)
        #expect(MarkdownPreviewWidth.fluid.help == "Narrow to a Reading Column")
        #expect(MarkdownPreviewWidth.contained.help == "Use the Full Width")
        #expect(MarkdownPreviewWidth.fluid.symbol != MarkdownPreviewWidth.contained.symbol)
    }

    @Test func theStoredFormRoundTrips() {
        for width in MarkdownPreviewWidth.allCases {
            #expect(MarkdownPreviewWidth(rawValue: width.rawValue) == width)
        }
    }
}

/// The document view, which does the arithmetic on its own width because a
/// `NSViewRepresentable` is never told that its view was resized.
@MainActor
struct MarkdownDocumentTextViewTests {
    @Test func aColumnIsCentredByWideningTheInset() {
        let textView = MarkdownPreviewView.makeTextView()
        textView.setFrameSize(NSSize(width: 1_600, height: 400))

        textView.measure = 500
        #expect(textView.textContainerInset.width == 550)

        textView.measure = nil
        #expect(textView.textContainerInset.width == MarkdownDocumentTextView.baseInset)
    }

    /// The gutters follow the window, which is the case the subclass exists
    /// for: nothing else is told that the pane was dragged narrower.
    @Test func aResizeRecomputesTheGutters() {
        let textView = MarkdownPreviewView.makeTextView()
        textView.setFrameSize(NSSize(width: 1_600, height: 400))
        textView.measure = 500
        #expect(textView.textContainerInset.width == 550)

        textView.setFrameSize(NSSize(width: 700, height: 400))
        #expect(textView.textContainerInset.width == 100)

        textView.setFrameSize(NSSize(width: 480, height: 400))
        #expect(textView.textContainerInset.width == MarkdownDocumentTextView.baseInset)
    }
}
