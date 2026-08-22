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
        #expect(options("Logo.SVG").supports(.image))
        #expect(options("Rows.CSV").supports(.table))
    }

    // MARK: Files whose subject is not their text

    /// An SVG keeps its source — that is the whole reason it is a
    /// presentation and not an `EditorMediaKind` — and gains exactly one way
    /// of being looked at. There is no prose in it to preview, and nothing
    /// worth putting beside it in a split.
    @Test func anSVGOffersItsPictureBesideItsSource() {
        let svg = options("logo.svg")
        #expect(svg.available == [.source, .image])
        #expect(!svg.supports(.preview))
        #expect(!svg.supports(.split))
    }

    @Test func aCSVOffersItsTableBesideItsSource() {
        let csv = options("members.csv")
        #expect(csv.available == [.source, .table])
        #expect(!csv.supports(.preview))
        #expect(!csv.supports(.split))
    }

    /// The rendering comes before the diff, so a file that offers all three
    /// reads source, then subject, then history — in that order, whatever
    /// the file is.
    @Test func aChangedSVGOrCSVStillOffersItsDiff() {
        #expect(options("logo.svg", changed: true).available == [.source, .image, .diff])
        #expect(options("rows.csv", changed: true).available == [.source, .table, .diff])
    }

    /// Neither is offered for anything but its own extension: a `.md` has no
    /// picture in it, and a `.txt` full of commas is not a spreadsheet.
    @Test func nothingElseIsOfferedAPictureOrATable() {
        for name in ["README.md", "main.swift", "data.txt", "a.png"] {
            let opts = options(name)
            #expect(!opts.supports(.image), "\(name)")
            #expect(!opts.supports(.table), "\(name)")
        }
    }

    /// Asked of the wrong file both fall back to source, which is what keeps
    /// the empty pane unreachable: a tab left in `.image` and reused for a
    /// `.swift` draws the code rather than a picture that does not exist.
    @Test func aPictureOrATableAskedOfTheWrongFileFallsBackToSource() {
        let swift = options("main.swift")
        #expect(swift.nearest(to: .image) == .source)
        #expect(swift.nearest(to: .table) == .source)
    }

    /// Neither can be the second half of a split, so neither changes what
    /// `splitPartner` answers.
    @Test func neitherAPictureNorATableIsASplitPartner() {
        #expect(options("logo.svg").splitPartner == nil)
        #expect(options("rows.csv").splitPartner == nil)
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

    // MARK: Where a file opens

    /// Nearly everything opens as source, Markdown included. This is a code
    /// editor: a file that opens in a mode you cannot type into surprises the
    /// person who opened it in order to type.
    @Test func mostDocumentsOpenAsSource() {
        for name in ["README.md", "guide.mdx", "main.swift", "notes.txt"] {
            #expect(EditorPresentation.opening(fileName: name) == .source, "\(name)")
        }
    }

    /// The two exceptions, and the same reason for both: the markup is not
    /// what the file is *for*. Nobody opens a logo to read its path data, and
    /// nobody opens an export to read its commas — the request that produced
    /// this was "it doesn't render", about a CSV that had opened as text.
    ///
    /// Source stays one press away in both, which is what makes rendering the
    /// safe default rather than a presumption.
    @Test func aFileWhoseMarkupIsNotThePointOpensRendered() {
        #expect(EditorPresentation.opening(fileName: "logo.svg") == .image)
        #expect(EditorPresentation.opening(fileName: "Logo.SVG") == .image)
        #expect(EditorPresentation.opening(fileName: "rows.csv") == .table)
        #expect(EditorPresentation.opening(fileName: "ROWS.CSV") == .table)
    }

    /// A document never opens on a presentation it does not offer.
    ///
    /// The seam worth guarding: availability is decided from the file *and*
    /// git, the opening posture from the file alone, and the two are written
    /// in different places. A file that opened on something it does not offer
    /// would draw an empty pane before anybody touched the control — except
    /// that `nearest` catches it, which is exactly why this is checked here
    /// instead of being left to it.
    @Test func aDocumentNeverOpensOnAPresentationItDoesNotOffer() {
        let names = ["README.md", "guide.mdx", "main.swift", "logo.svg", "rows.csv", "a.png", "contract.pdf"]
        for name in names {
            for changed in [false, true] {
                let opening = EditorPresentation.opening(fileName: name)
                #expect(options(name, changed: changed).supports(opening), "\(name) changed:\(changed)")
            }
        }
    }
}

/// The opening posture reaches the document, which is the only place it can
/// be applied once and then remembered.
///
/// Applying it in the view instead would undo the toggle every time the tab
/// came back: `EditorPaneView` is rebuilt from scratch on every switch, so an
/// `onAppear` that set the posture would put a reader who asked for the
/// source of an SVG back into the picture on their return.
@MainActor
struct EditorDocumentOpeningPresentationTests {
    private func document(_ name: String) -> EditorDocument {
        EditorDocument(url: URL(fileURLWithPath: "/tmp/\(name)"), text: "")
    }

    @Test func anSVGIsCreatedShowingItsPicture() {
        #expect(document("logo.svg").presentation == .image)
    }

    @Test func aCSVIsCreatedShowingItsTable() {
        #expect(document("rows.csv").presentation == .table)
    }

    @Test func anOrdinaryFileIsCreatedShowingItsSource() {
        #expect(document("main.swift").presentation == .source)
        #expect(document("README.md").presentation == .source)
    }
}
