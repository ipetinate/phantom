import Foundation

/// What one request for completions came back with.
///
/// An enum rather than an array because **an empty answer and a superseded one
/// are different instructions**, and spelling both `[]` makes the list flicker
/// on exactly the keystrokes it should be refining.
///
/// A request in flight is cancelled by the next one, either locally or by the
/// server itself — `typescript-language-server` cancels the previous
/// `textDocument/completion` when a change arrives, and answers the abandoned
/// one with an empty list and no error. Typing quickly therefore produces a
/// steady stream of empty answers that mean "ignore me", interleaved with real
/// ones. A caller that clears the list whenever it receives nothing will blank
/// the panel between every pair of keystrokes, which reads as the feature being
/// broken rather than as a race.
///
/// So the two are separate cases, and the rule is one line: `items` may clear
/// the list, `unchanged` may never.
///
/// Deliberately an engine type even though only the host ever constructs one.
/// The engine's contract is that it takes what it needs as values and never
/// learns that a language server exists, so the vocabulary the provider speaks
/// has to belong to the side that draws it.
enum CodeCompletionAnswer: Equatable, Sendable {
    /// The server answered. Empty means it had nothing to suggest here, which
    /// is a fact worth drawing — the list should close.
    case items([CodeCompletionItem])

    /// No usable answer arrived: the request was cancelled or superseded.
    /// Whatever is on screen stays there.
    case unchanged
}
