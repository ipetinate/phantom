import Foundation
@testable import Ghostty
import Testing

/// Which ways a document can be shown, decided from the file rather than
/// from a stored preference.
///
/// The property worth protecting is that a control can only ever offer a
/// presentation that works. Offering everything and failing at draw time is
/// how a toggle ends up with a state that shows an empty pane.
struct EditorPresentationTests {
    private func options(_ name: String, changed: Bool = false) -> EditorPresentationOptions {
        .resolve(fileName: name, hasChanges: changed)
    }

    // MARK: What each kind of file offers

    /// A plain source file with no changes has one honest answer.
    @Test func anUnchangedSourceFileOffersOnlyItsSource() {
        #expect(options("CodeTextView.swift").available == [.source])
    }

    @Test func markdownOffersAPreviewAndASplit() {
        let md = options("README.md")
        #expect(md.supports(.preview))
        #expect(md.supports(.split))
        #expect(!md.supports(.diff))
    }

    /// `.mdx` gets a preview because its prose *is* Markdown — the JSX it
    /// adds is shown as code rather than evaluated. Excluding it would leave
    /// a file of forty paragraphs and three components with no preview at
    /// all.
    @Test func mdxIsMarkdownEnoughToPreview() {
        #expect(options("guide.mdx").supports(.preview))
    }

    @Test func extensionsAreMatchedWithoutCaringAboutCase() {
        #expect(options("README.MD").supports(.preview))
        #expect(options("Notes.Markdown").supports(.preview))
    }

    /// A diff is offered, a split is **not**: the diff is already two panes
    /// of one file, and nesting it inside another split would put three
    /// panes and two direction toggles on screen to answer a question the
    /// diff's own left column already answers.
    @Test func aChangedFileOffersADiffButNotASplit() {
        let changed = options("GitCenter.swift", changed: true)
        #expect(changed.supports(.diff))
        #expect(!changed.supports(.split))
        #expect(!changed.supports(.preview))
    }

    /// Source is first everywhere, because it is the one every file has and
    /// the one a reader falls back to.
    @Test func sourceComesFirstWhateverElseIsOffered() {
        for opts in [options("a.swift"), options("b.md"), options("c.ts", changed: true)] {
            #expect(opts.available.first == .source)
        }
    }

    // MARK: The split's second pane

    /// A split needs something to sit beside the source. Offering the button
    /// with nothing to put there opens a blank half, which is worse than no
    /// button.
    @Test func nothingToPairWithMeansNoSplit() {
        #expect(!options("main.swift").supports(.split))
        #expect(options("main.swift").splitPartner == nil)
    }

    @Test func aPreviewIsTheSplitPartnerForCleanMarkdown() {
        #expect(options("README.md").splitPartner == .preview)
    }

    /// Changed Markdown offers all four, and its split is still source
    /// beside preview. The diff stays a presentation of its own rather than
    /// becoming half of one, because it already has two panes.
    @Test func changedMarkdownStillSplitsAgainstItsPreview() {
        let both = options("README.md", changed: true)
        #expect(both.supports(.diff))
        #expect(both.supports(.preview))
        #expect(both.splitPartner == .preview)
    }

    // MARK: Falling back

    /// Committing while a diff is on screen removes the thing being shown.
    /// Landing on source is the only answer that is always available.
    @Test func aPresentationThatStopsBeingAvailableFallsBackToSource() {
        let afterCommit = options("GitCenter.swift", changed: false)
        #expect(afterCommit.nearest(to: .diff) == .source)
        #expect(afterCommit.nearest(to: .split) == .source)
    }

    @Test func anAvailablePresentationIsLeftAlone() {
        let md = options("README.md")
        #expect(md.nearest(to: .preview) == .preview)
        #expect(md.nearest(to: .source) == .source)
    }

    /// Every document opens as source, Markdown included. This is a code
    /// editor: a file that opens in a mode you cannot type into surprises
    /// the person who opened it in order to type.
    @Test func everyDocumentOpensAsSource() {
        #expect(options("README.md").initial == .source)
        #expect(options("x.swift", changed: true).initial == .source)
    }
}
