import Foundation

/// How a document is being shown, as opposed to what it contains.
///
/// Until now a tab had exactly one answer — the text view — and the question
/// was never asked. Two things ask it: a Markdown file can be read as source
/// or as prose, and a changed file can be read as itself or as a diff against
/// what it was.
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

    /// What a document opens as.
    ///
    /// Source, always — including for Markdown. This is a code editor, and a
    /// file that opens in a mode you cannot type into surprises the person
    /// who opened it to type. The toggle is one click and it is remembered.
    var initial: EditorPresentation { .source }

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
        if hasChanges { available.append(.diff) }

        /// A split needs something to sit beside the source. With neither a
        /// preview nor a diff there is no second pane to offer, and a split
        /// button that opens a blank half is worse than no button.
        if isMarkdown || hasChanges { available.append(.split) }

        return EditorPresentationOptions(available: available)
    }

    /// What the second pane of a split holds.
    ///
    /// A diff wins over a preview when a Markdown file has both, because at
    /// that moment the reader has changes in front of them: the question
    /// "what did I change" is more urgent than "how does this read", and the
    /// preview is one click away either way.
    var splitPartner: EditorPresentation? {
        if supports(.diff) { return .diff }
        if supports(.preview) { return .preview }
        return nil
    }
}
