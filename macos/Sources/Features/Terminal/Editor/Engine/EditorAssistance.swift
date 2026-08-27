import Foundation

/// Which of the things the editor does unasked the reader still wants.
///
/// A value, and the engine's own shape for the answer, for the reason the
/// whole `Editor/Engine/` boundary exists and `EditorEngineBoundaryTests`
/// enforces: **the engine is told, it does not ask.** A component that reads
/// preferences behind its host's back cannot be configured by a different
/// host, and cannot be tested without whatever store it reached for — which
/// is not a hypothetical here. These decide whether a keystroke opens a list
/// and whether a pointer opens a card, so an engine that read them from a
/// global would make every test of typing depend on the machine's own
/// settings, and on whatever other test happened to be running beside it.
///
/// Everything defaults to on, so a view nobody has configured behaves like an
/// editor rather than like a stripped one. That is also what makes a bare
/// `CodeNSTextView` in a test complete, hover and import without being told
/// anything.
///
/// The host collapses its preferences into this and hands it over. What those
/// preferences are called, where they are stored, and whether there is a
/// settings window at all are none of the engine's business.
struct EditorAssistance: Equatable, Sendable {
    /// Whether accepting a completion may add the import it needs — and, with
    /// it, whether the accept waits for the producer to finish the row at all.
    var autoImport = true

    /// Whether the caret's line shows who last changed it.
    var gitLens = true

    /// Whether resting the pointer opens documentation.
    var hoverCards = true

    /// Whether the margin marks lines that differ from the committed file.
    ///
    /// The margin only. Which lines the reader has changed is a separate
    /// question asked of the same comparison — the git lens needs it to stay
    /// quiet on a line the reader has rewritten — and it keeps being answered
    /// whatever this says.
    var diffMarks = true

    /// Whether a list of completions appears as the reader types.
    ///
    /// Not whether completion works: an explicit request still asks. See
    /// `CodeNSTextView.completionRequestVerdict`, which is where the two
    /// switches are told apart.
    var completionWhileTyping = true

    /// Whether problems are marked in the text.
    var inlineDiagnostics = true

    /// The whole editor, which is what a view that has been told nothing has.
    static let all = EditorAssistance()
}
