import Foundation

/// How a document is being shown, as opposed to what it contains.
///
/// Until now a tab had exactly one answer — the text view — and the question
/// was never asked. Several things ask it: a Markdown file can be read as
/// source or as prose, a changed file as itself or as a diff against what it
/// was, and an SVG or a CSV as the picture or the grid that its text stands
/// for rather than as the text itself.
///
/// Deliberately a property of the **document** rather than of the view. A tab
/// switched away from and back to should return the way it was left; view
/// state does not survive that, and a reader who put a README into preview
/// and glanced at another file did not ask to be put back into source.
enum EditorPresentation: Equatable, Hashable, CaseIterable, Sendable {
    /// The editable source. Every document supports this, and it is what a
    /// document that supports nothing else is stuck with.
    case source

    /// Markdown drawn as prose.
    case preview

    /// An SVG drawn as the picture its markup describes.
    ///
    /// Not folded into `.preview` even though both render, because the two
    /// are offered by different files and a presentation is only honest if
    /// every document that offers it can draw it. A single "the rendered
    /// one" case would let the control offer Markdown's prose renderer for a
    /// `.svg`, which is exactly the empty pane this type exists to prevent.
    case image

    /// Delimited text laid out as the grid it stands for.
    case table

    /// The file against a git revision.
    case diff

    /// Source and the alternative at once, in a split.
    ///
    /// One case rather than `splitPreview` and `splitDiff`, because which
    /// alternative it pairs with is decided by what the document *offers* —
    /// and a document never offers both preview and diff at once, since a
    /// `.md` with changes is still read as prose or as a diff, never as
    /// prose *and* a diff in the same two panes.
    case split

    /// What a file opens as, before anybody has toggled anything.
    ///
    /// Source for nearly everything, and for the reason this is a code
    /// editor: a file that opens in a mode you cannot type into surprises the
    /// person who opened it to type. Markdown obeys that despite rendering
    /// beautifully, and so does a CSV — reading the raw rows is one of the two
    /// honest reasons to open one, so its table is offered rather than
    /// imposed.
    ///
    /// An SVG is the exception, because its markup is not what the file is
    /// *for*. Nobody opens a logo to read its path data; they open it to see
    /// the logo, and the reader who did come to edit it is one click from the
    /// source, which is then remembered for the rest of the sitting.
    ///
    /// Answered from the name alone, and deliberately not routed through an
    /// `EditorPresentationOptions`: whether git has something to compare the
    /// file against is not what decides where it lands. A file reached from
    /// the Changes list opens on its diff because the *caller* asked for that
    /// — `EditorCenter.open(showing:)` — not because it happened to be dirty
    /// when somebody opened it from the sidebar.
    static func opening(fileName: String) -> EditorPresentation {
        let options = EditorPresentationOptions.resolve(fileName: fileName, hasChanges: false)
        if options.supports(.image) { return .image }
        if options.supports(.table) { return .table }
        return .source
    }
}

/// Which presentations a document can actually be shown in.
///
/// Answered from facts about the file rather than from a stored preference,
/// so a control can only ever offer something that works. The alternative —
/// offering everything and failing at draw time — is how a toggle ends up
/// with a state that shows an empty pane.
struct EditorPresentationOptions: Equatable, Sendable {
    /// Ordered as they should appear in a control: source first, because it
    /// is the one every file has and the one a reader falls back to.
    let available: [EditorPresentation]

    func supports(_ presentation: EditorPresentation) -> Bool {
        available.contains(presentation)
    }

    /// What to fall back to when a presentation stops being available —
    /// a diff on a file whose changes were just committed, say.
    ///
    /// Never nil, because `.source` is always in the list.
    func nearest(to presentation: EditorPresentation) -> EditorPresentation {
        supports(presentation) ? presentation : .source
    }

    /// Extensions read as Markdown.
    ///
    /// `.mdx` is here because its prose *is* Markdown — what it adds is JSX,
    /// which the renderer shows as code rather than pretending to evaluate.
    /// Excluding it would mean an MDX file with three components and forty
    /// paragraphs gets no preview at all, which serves nobody.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    /// - Parameter hasChanges: whether git reports this path as modified.
    ///   Passed in rather than looked up, so this stays a value decision the
    ///   tests can drive — and so the editor does not learn what git is.
    static func resolve(fileName: String, hasChanges: Bool) -> EditorPresentationOptions {
        var available: [EditorPresentation] = [.source]

        let ext = (fileName as NSString).pathExtension.lowercased()
        let isMarkdown = markdownExtensions.contains(ext)

        if isMarkdown { available.append(.preview) }

        /// An SVG and a CSV are the two files here whose *source* is text
        /// somebody edits and whose *subject* is something else — a picture
        /// and a grid. That is why they are presentations rather than entries
        /// in `EditorMediaKind`: a PNG has no source to return to, so a media
        /// tab costs its reader nothing, while sending an SVG there would
        /// trade away the ability to edit a text file for a rendering nobody
        /// asked for.
        if ext == "svg" { available.append(.image) }
        if ext == "csv" { available.append(.table) }

        if hasChanges { available.append(.diff) }

        /// A split needs something to sit beside the source, and only a
        /// preview qualifies.
        ///
        /// A picture and a table are left out for a duller reason than the
        /// diff's: the second pane is scroll-linked to the first, and the
        /// machinery that does the linking maps Markdown blocks to source
        /// lines. There is no such mapping from a rendered SVG back to the
        /// attribute that drew it, and a table's rows do not scroll with the
        /// text that spells them once a cell wraps.
        ///
        /// **A diff is already a split** — two columns of one file, with
        /// its own divider and its own direction toggle. Offering "source
        /// beside the diff" would nest one split inside another: three
        /// panes, two dividers and two toggles in one corner, to answer a
        /// question the diff's own left column already answers, since that
        /// column *is* the source as it stands in the revision being
        /// compared against.
        if isMarkdown { available.append(.split) }

        return EditorPresentationOptions(available: available)
    }

    /// What the second pane of a split holds.
    ///
    /// Only ever the preview, for the reason `resolve` gives: a diff brings
    /// its own two panes, so it is a presentation of its own rather than
    /// half of one.
    var splitPartner: EditorPresentation? {
        supports(.preview) ? .preview : nil
    }
}
