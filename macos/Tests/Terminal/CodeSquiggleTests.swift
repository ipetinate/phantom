import AppKit
@testable import Ghostty
import Testing

/// The wave drawn under a problem.
///
/// All arithmetic, which is the point: the drawing needs a laid-out text
/// view, a window and a font, and the part that is easy to get wrong needs
/// none of them. What is asserted here is what a reader would complain about
/// — a smear at small sizes, a caricature at large ones, a mark that runs
/// past the word it belongs to, and a trough drawn over the line below.
struct CodeSquiggleTests {
    // MARK: It scales with the type

    /// The reference size. A 12pt font gets a 6pt period and a wave a little
    /// under 3pt tall, which is the proportion VS Code draws.
    @Test func theDefaultFontSizeGetsTheReferenceWave() {
        #expect(CodeSquiggle.wavelength(forFontSize: 12) == 6)
        #expect(abs(CodeSquiggle.amplitude(forFontSize: 12) - 1.38) < 0.01)
        #expect(CodeSquiggle.lineWidth(forFontSize: 12) == 1)
    }

    @Test func everyMeasurementGrowsWithTheFont() {
        for (small, large) in [(9.0, 12.0), (12.0, 16.0), (16.0, 20.0)] {
            #expect(CodeSquiggle.wavelength(forFontSize: small) < CodeSquiggle.wavelength(forFontSize: large))
            #expect(CodeSquiggle.amplitude(forFontSize: small) < CodeSquiggle.amplitude(forFontSize: large))
        }
    }

    /// The floor. Below it the peaks land inside one another and the wave
    /// fills in solid, which is the "straight line, but blurry" the reader
    /// was already complaining about.
    @Test func aTinyFontStillGetsASeparableWave() {
        let wavelength = CodeSquiggle.wavelength(forFontSize: 4)
        let amplitude = CodeSquiggle.amplitude(forFontSize: 4)

        #expect(wavelength >= 3)
        #expect(amplitude >= 0.75)
        #expect(CodeSquiggle.lineWidth(forFontSize: 4) >= 0.75)
    }

    /// The ceiling. Past it the mark stops being an underline and becomes a
    /// decoration the reader sees before they see the word.
    @Test func aHugeFontDoesNotGetAHugeWave() {
        #expect(CodeSquiggle.wavelength(forFontSize: 96) <= 12)
        #expect(CodeSquiggle.amplitude(forFontSize: 96) <= 3)
        #expect(CodeSquiggle.lineWidth(forFontSize: 96) <= 2)
    }

    // MARK: It stops where the problem stops

    /// The reported complaint, in geometry: a diagnostic covering three
    /// characters must not paint under the rest of the line. The rect handed
    /// in is the three characters' own, and nothing may be drawn outside it.
    @Test func theWaveEndsWhereTheRangeEnds() {
        let width: CGFloat = 21
        let points = CodeSquiggle.points(
            x: 40, width: width, centreY: 100, wavelength: 6, amplitude: 1.4)

        #expect(points.first?.x == 40)
        #expect(points.last?.x == 40 + width)
        #expect(points.allSatisfy { $0.x >= 40 && $0.x <= 40 + width })
    }

    /// The ends sit on the centre line rather than at a peak, so the mark
    /// starts and finishes flat against the characters either side of it.
    @Test func bothEndsAreOnTheCentreLine() {
        let points = CodeSquiggle.points(
            x: 0, width: 30, centreY: 100, wavelength: 6, amplitude: 1.4)

        #expect(points.first?.y == 100)
        #expect(points.last?.y == 100)
    }

    /// Every vertex between the ends alternates, which is what makes it a
    /// wave rather than a row of bumps.
    @Test func theVerticesAlternateAroundTheCentre() {
        let points = CodeSquiggle.points(
            x: 0, width: 30, centreY: 100, wavelength: 6, amplitude: 1.4)
        let middle = points.dropFirst().dropLast()

        #expect(middle.count >= 4)
        for (index, point) in middle.enumerated() {
            let expected = index.isMultiple(of: 2) ? 100 - 1.4 : 100 + 1.4
            #expect(abs(point.y - expected) < 0.001, "vertex \(index) at \(point.y)")
        }
    }

    /// A problem on one character is still a wave. Squeezing the wavelength
    /// down to the run's own width is what buys that — at the full
    /// wavelength a run this narrow has no room for a peak and comes out as
    /// a short straight dash, which is the mark this whole change replaces.
    @Test func aSingleCharacterStillGetsAPeak() {
        let points = CodeSquiggle.points(
            x: 0, width: 4, centreY: 100, wavelength: 12, amplitude: 1.4)

        #expect(points.count >= 3)
        #expect(points.contains { $0.y != 100 })
    }

    @Test func nothingIsDrawnForAnEmptyRange() {
        #expect(CodeSquiggle.points(
            x: 0, width: 0, centreY: 100, wavelength: 6, amplitude: 1.4).isEmpty)
        #expect(CodeSquiggle.path(x: 0, width: 0, centreY: 100, fontSize: 12) == nil)
    }

    // MARK: It stays on its own line

    /// Under the baseline, always. A wave centred on it would be struck
    /// through the glyphs instead of drawn under them.
    @Test func theWaveSitsBelowTheBaseline() {
        let centre = CodeSquiggle.centreY(
            baseline: 20, bottom: 30, amplitude: 1.4, lineWidth: 1)

        #expect(centre > 20)
    }

    /// And inside the line fragment. A trough that reaches past the bottom is
    /// drawn over the first row of the line below — where nothing knows it is
    /// there, so nothing ever takes it away.
    @Test func theTroughStaysInsideTheLine() {
        let amplitude: CGFloat = 1.4
        let stroke: CGFloat = 1
        let centre = CodeSquiggle.centreY(
            baseline: 20, bottom: 24, amplitude: amplitude, lineWidth: stroke)

        #expect(centre + amplitude + stroke / 2 <= 24.001)
    }

    /// A line too tight to hold the wave keeps it on the baseline rather than
    /// letting it spill. Overlapping a descender is a blemish; bleeding into
    /// the next line is an artefact that outlives the diagnostic.
    @Test func aLineWithNoRoomKeepsTheWaveOnTheBaseline() {
        let centre = CodeSquiggle.centreY(
            baseline: 20, bottom: 20.5, amplitude: 1.4, lineWidth: 1)

        #expect(centre >= 20)
        #expect(centre <= 20 + 1.4 + 0.5 + 0.001)
    }

    /// Given room, it takes the gap it wants rather than sitting as high as
    /// it is allowed to.
    @Test func aRoomyLineGetsTheFullGap() {
        let centre = CodeSquiggle.centreY(
            baseline: 20, bottom: 60, amplitude: 1.4, lineWidth: 1)

        #expect(abs(centre - (20 + 1.4 + 1)) < 0.001)
    }

    // MARK: How far it may hang over

    /// The number the redraw is padded by. Understating it leaves the hanging
    /// fraction of a wave erased by the line below being repainted, with
    /// nothing to put it back — which is the artefact a mark drawn outside
    /// its own line invites.
    @Test func theOverhangCoversTheWholeReachOfTheWave() {
        for size in [9.0, 12.0, 16.0, 24.0] {
            let expected = CodeSquiggle.amplitude(forFontSize: size)
                + CodeSquiggle.lineWidth(forFontSize: size) / 2

            #expect(CodeSquiggle.maximumOverhang(forFontSize: size) == expected)
        }
    }

    /// The measured case, and the reason the overhang is not zero: a 12pt
    /// monospaced line lays out 15pt tall with its baseline at 12, leaving
    /// three points of descent for a mark that stands nearly four.
    @Test func aTwelvePointLineHasNoRoomAndKeepsThePeakOnTheBaseline() {
        let amplitude = CodeSquiggle.amplitude(forFontSize: 12)
        let stroke = CodeSquiggle.lineWidth(forFontSize: 12)
        let centre = CodeSquiggle.centreY(
            baseline: 12, bottom: 15, amplitude: amplitude, lineWidth: stroke)

        #expect(centre - amplitude - stroke / 2 >= 12 - 0.001)
        #expect(centre + amplitude + stroke / 2
            <= 15 + CodeSquiggle.maximumOverhang(forFontSize: 12) + 0.001)
    }

    // MARK: The path

    @Test func thePathCarriesTheStrokeWidthForTheFont() {
        let path = CodeSquiggle.path(x: 0, width: 40, centreY: 10, fontSize: 18)

        #expect(path != nil)
        #expect(path?.lineWidth == CodeSquiggle.lineWidth(forFontSize: 18))
        #expect(path?.lineJoinStyle == .round)
    }
}
