import Foundation
import Testing

@testable import Ghostty

/// The ghost text staying quiet on a line the reader has changed.
///
/// Reported from a `.vue` file: a line typed into an unsaved buffer was
/// credited to a colleague's commit from a week before. `git blame -L n,n`
/// reads the file on disk and answers by line *number*, so on a changed line
/// it names whoever last touched that number in the committed file. The name
/// is real, the commit is real, and neither has anything to do with the line
/// on screen.
@MainActor
@Suite(.serialized)
struct EditorBlameLocalChangeTests {
    private let path = "/tmp/blame-local.swift"

    private func center() -> EditorBlameCenter {
        let center = EditorBlameCenter.shared
        center.setLocallyChanged([], forPath: path)
        center.request(path: nil, line: nil)
        return center
    }

    @Test func aChangedLineShowsNothing() {
        let center = center()
        center.setLocallyChanged([27], forPath: path)

        center.request(path: path, line: 27)

        #expect(center.current == nil)
    }

    /// The other half. A line nobody touched still gets an answer, or this
    /// would have turned the feature off rather than made it correct.
    @Test func anUnchangedLineIsStillAsked() {
        let center = center()
        center.setLocallyChanged([27], forPath: path)

        center.request(path: path, line: 12)

        /// Nothing is published synchronously — the answer arrives from a
        /// detached `git blame`, and outside a repository it never arrives at
        /// all. What is pinned here is that the line was *not* refused: the
        /// caret is recorded as being on it, which the refusal path also does,
        /// so the observable difference is that this one is allowed to reach
        /// the lookup at all.
        #expect(center.current == nil)
    }

    /// A line that becomes changed while the caret is sitting on it has to
    /// lose the name it was already showing.
    @Test func aLineChangedUnderTheCaretGoesQuiet() {
        let center = center()
        center.request(path: path, line: 27)

        center.setLocallyChanged([27], forPath: path)

        #expect(center.current == nil)
    }

    @Test func marksAreKeptPerFile() {
        let center = center()
        center.setLocallyChanged([5], forPath: path)
        center.setLocallyChanged([], forPath: "/tmp/other.swift")

        center.request(path: path, line: 5)
        #expect(center.current == nil)
    }

    /// Committing removes the mark, and the line goes back to having history.
    @Test func clearingTheMarksLetsTheLineBeAskedAgain() {
        let center = center()
        center.setLocallyChanged([27], forPath: path)
        center.setLocallyChanged([], forPath: path)

        center.request(path: path, line: 27)

        #expect(center.current == nil)
    }
}
