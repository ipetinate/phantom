import AppKit
@testable import Ghostty
import Testing

/// What the SVG pane will and will not draw.
///
/// The premise underneath the whole presentation is measured by the first
/// test: AppKit decodes SVG itself, so showing one costs no renderer, no
/// dependency and no web view. Everything else here is about the second
/// failure — markup that decodes into an image of no size, which draws as a
/// pane with nothing in it and would look exactly like a feature that does
/// not work.
struct EditorSVGImageTests {
    private let square = """
    <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
      <rect width="120" height="80" fill="#2b6cb0"/>
    </svg>
    """

    @Test func markupThatDescribesAPictureDecodesToTheSizeItAsksFor() throws {
        let image = try #require(EditorSVGImage.decode(square))
        #expect(image.size == CGSize(width: 120, height: 80))
    }

    /// A `viewBox` with no width or height is the shape a hand-written icon
    /// usually arrives in, and it is still a size.
    @Test func aViewBoxIsEnoughOfASize() throws {
        let markup = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20">
          <rect width="40" height="20"/>
        </svg>
        """
        let image = try #require(EditorSVGImage.decode(markup))
        #expect(image.size == CGSize(width: 40, height: 20))
    }

    /// The buffer is read as UTF-8, so a label in it is not what breaks the
    /// picture.
    @Test func textInTheMarkupSurvivesBeingEncoded() throws {
        let markup = """
        <svg xmlns="http://www.w3.org/2000/svg" width="60" height="20">
          <text x="4" y="14">Ação — 100%</text>
        </svg>
        """
        let image = try #require(EditorSVGImage.decode(markup))
        #expect(image.size == CGSize(width: 60, height: 20))
    }

    /// Nothing here is a picture, and none of it should reach the viewer.
    /// The truncated case is the one that happens for real: a `.svg` saved
    /// halfway through an edit.
    @Test func markupThatIsNotAPictureDoesNotDecode() {
        let rejected = [
            #"<svg xmlns="http://www.w3.org/2000/svg" width="10" heig"#,
            "",
            "   \n  ",
            "<html><body>hi</body></html>",
            #"{"width": 10}"#,
            "plain prose that happens to live in a .svg",
        ]

        for markup in rejected {
            #expect(EditorSVGImage.decode(markup) == nil, "\(markup)")
        }
    }

    /// The failure worth having, because AppKit calls it a success.
    ///
    /// `<svg/>` and a zero width both hand back a valid image reporting a
    /// size of zero. Drawn, that is an empty pane with no explanation —
    /// indistinguishable from a broken toggle. Refused, it is a sentence.
    @Test func aPictureWithNoSizeIsRefused() {
        let sizeless = [
            #"<svg xmlns="http://www.w3.org/2000/svg"/>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"/>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" width="-4" height="-4"/>"#,
        ]

        for markup in sizeless {
            #expect(EditorSVGImage.decode(markup) == nil, "\(markup)")
        }
    }
}
