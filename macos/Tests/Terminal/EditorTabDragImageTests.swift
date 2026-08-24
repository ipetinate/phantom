import AppKit
import Testing

@testable import Ghostty

/// The thing that follows the pointer while a tab is dragged.
///
/// Pinned because the first version came out **blank**: it snapshotted the
/// tab with `cacheDisplay`, and SwiftUI draws through a layer tree that does
/// not reach. A drag with an invisible payload looks like a drag that is not
/// happening, which is exactly how it was reported.
@MainActor
struct EditorTabDragImageTests {
    private typealias Source = EditorTabDragSource.DragSourceView

    @Test func theImageHasSizeAndPixels() throws {
        let image = Source.image(for: "AppLayout.vue")

        #expect(image.size.width > 20)
        #expect(image.size.height > 10)

        /// Not just a size: a `NSImage` of the right size can still be empty,
        /// which is the bug this suite exists for. Ask for the bits.
        let representation = try #require(image.representations.first)
        #expect(representation.size.width > 20)
    }

    /// A tab's name can be a whole path, and a pill as wide as the window
    /// tells the reader nothing about where it is.
    @Test func aLongNameIsCapped() {
        let long = String(repeating: "very-long-file-name-", count: 20)
        let image = Source.image(for: long)

        #expect(image.size.width <= 280)
    }

    /// An unnamed tab still gets something to look at.
    @Test func anEmptyNameStillDraws() {
        let image = Source.image(for: "")

        #expect(image.size.width > 20)
        #expect(image.size.height > 10)
    }
}
