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
    ///
    /// - Parameter isIncomplete: The producer calling its own answer a guess
    ///   for the prefix it was asked about, and asking to be asked again as
    ///   that prefix grows. Carried rather than dropped because the next
    ///   request has to say that it is a refinement — see
    ///   `CodeCompletionRequest.isRefiningIncompleteList`.
    case items([CodeCompletionItem], isIncomplete: Bool)

    /// No usable answer arrived: the request was cancelled or superseded.
    /// Whatever is on screen stays there.
    case unchanged
}

/// What the engine asks its provider for.
///
/// A value rather than a bare offset, because two of the three things a
/// producer needs are facts only the engine has: which key produced this
/// request, and whether the answer already on screen was called a guess.
/// Both were being withheld — the offset went out on its own and the producer
/// had to pretend every request was somebody asking from nothing.
///
/// Deliberately an engine type, and deliberately spelled in the engine's own
/// vocabulary: it says "a character was typed", not "trigger kind 2". What a
/// producer makes of that is the producer's business, and the engine is not
/// allowed to know that a language server is on the other end.
struct CodeCompletionRequest: Equatable, Sendable {
    /// Where in the document to complete.
    var offset: Int

    /// The character whose arrival opened or refined the list, when one did.
    ///
    /// Nil for a request nobody typed: ⌃Space, and a backspace narrowing the
    /// list that is already up.
    var typedCharacter: Character?

    /// Whether the answer this one replaces was marked incomplete.
    ///
    /// The producer asked to be asked again; this says the re-ask has
    /// arrived. Without it a refinement is indistinguishable from a fresh
    /// request, and a producer that ranks or filters differently for the two
    /// has been answering the wrong question.
    var isRefiningIncompleteList: Bool

    init(
        offset: Int,
        typedCharacter: Character? = nil,
        isRefiningIncompleteList: Bool = false
    ) {
        self.offset = offset
        self.typedCharacter = typedCharacter
        self.isRefiningIncompleteList = isRefiningIncompleteList
    }
}
