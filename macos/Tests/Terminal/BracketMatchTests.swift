import Foundation
@testable import Ghostty
import Testing

/// Pairing the bracket under the caret with the one that closes it.
///
/// Every case here is one of the ways this feature looks broken when it is
/// got wrong on screen, stated as arithmetic instead: a caret resting *past*
/// a closer, a brace that is really a character in a string, and text that
/// does not balance — where the only acceptable answer is nothing at all.
struct BracketMatchTests {
    private func pair(
        _ source: String,
        caret: Int,
        skipping: [NSRange] = [],
        limit: Int = BracketMatch.searchLimit
    ) -> BracketMatch.Pair? {
        BracketMatch.pair(
            in: source as NSString,
            caret: caret,
            skipping: skipping,
            limit: limit
        )
    }

    /// Offsets rather than ranges, because every bracket is one character and
    /// a test that spelled out `NSRange(location:length:)` twice per
    /// expectation would hide what it is checking.
    private func offsets(
        _ source: String,
        caret: Int,
        skipping: [NSRange] = [],
        limit: Int = BracketMatch.searchLimit
    ) -> [Int]? {
        pair(source, caret: caret, skipping: skipping, limit: limit)
            .map { [$0.open.location, $0.close.location] }
    }

    // MARK: - Where the caret counts as "on" a bracket

    @Test func theCaretOnAnOpenerFindsItsCloser() {
        #expect(offsets("{ }", caret: 0) == [0, 2])
    }

    @Test func theCaretOnACloserFindsItsOpener() {
        #expect(offsets("{ }", caret: 2) == [0, 2])
    }

    /// The case that makes this feel right at the moment a block is finished,
    /// and the one most likely to be left out: typing `}` leaves the caret
    /// *past* it, so a rule that only looked at the character under the caret
    /// would light nothing exactly then. VS Code matches it; so does this.
    @Test func theCaretAfterACloserStillFindsThePair() {
        #expect(offsets("{ }", caret: 3) == [0, 2])
    }

    /// And the character before the caret is the one tried first. Here the two
    /// candidates belong to different pairs, so the order is visible: before
    /// the caret is the `)` of the first pair, under it the `{` of the second.
    @Test func theCharacterBeforeTheCaretIsPreferred() {
        #expect(offsets("(){}", caret: 2) == [0, 1])
    }

    /// A closer with no opener does not veto the candidate under the caret.
    /// A file being typed is unbalanced most of the time, and a stray `}`
    /// behind the caret must not blind it to the brace it is standing on.
    @Test func anUnmatchedCandidateDoesNotHideTheOtherOne() {
        #expect(offsets("}{}", caret: 1) == [1, 2])
    }

    @Test func theCaretOnOrdinaryTextMatchesNothing() {
        #expect(pair("let a = 1", caret: 4) == nil)
    }

    // MARK: - Nesting

    @Test func theInnermostPairWins() {
        #expect(offsets("((()))", caret: 3) == [2, 3])
        #expect(offsets("((()))", caret: 0) == [0, 5])
    }

    @Test func mixedKindsNestTogether() {
        #expect(offsets("([{}])", caret: 0) == [0, 5])
        #expect(offsets("([{}])", caret: 2) == [1, 4])
    }

    /// Backwards over a nested pair, which is the direction a naive
    /// implementation gets wrong: it has to skip the whole `{}` rather than
    /// stopping at the first opener it meets.
    @Test func theBackwardWalkSkipsAnInnerPair() {
        #expect(offsets("( {} )", caret: 5) == [0, 5])
    }

    // MARK: - Strings and comments

    /// The same ranges the depth colouring is given, and for the same reason:
    /// a brace inside a literal is a character, not an open block.
    @Test func aBracketInsideAStringIsNotAPartner() {
        let source = #"{ "}" }"#
        let literal = (source as NSString).range(of: #""}""#)

        #expect(offsets(source, caret: 0, skipping: [literal]) == [0, 6])
    }

    /// And the walk backwards has to ignore it too, or the closer at the end
    /// would pair with the quote's brace instead of the real opener.
    @Test func theBackwardWalkIgnoresAStringToo() {
        let source = #"{ "{" }"#
        let literal = (source as NSString).range(of: #""{""#)

        #expect(offsets(source, caret: 7, skipping: [literal]) == [0, 6])
    }

    /// A caret resting on a bracket that is itself inside a literal matches
    /// nothing — anything else would draw a line from inside a string out
    /// into the code around it.
    @Test func theCaretOnABracketInsideAStringMatchesNothing() {
        let source = #"{ "}" }"#
        let literal = (source as NSString).range(of: #""}""#)

        #expect(pair(source, caret: 3, skipping: [literal]) == nil)
        #expect(pair(source, caret: 4, skipping: [literal]) == nil)
    }

    @Test func aBracketInsideACommentIsIgnored() {
        let source = "{\n// }\n}"
        let comment = (source as NSString).range(of: "// }")

        #expect(offsets(source, caret: 0, skipping: [comment]) == [0, 7])
    }

    // MARK: - Text that does not balance

    /// No partner within reach is no highlight. The alternative — lighting the
    /// opener alone — says "this is a pair" about something that is not one.
    @Test func anOpenerWithNoCloserMatchesNothing() {
        #expect(pair("{ let a = 1", caret: 0) == nil)
    }

    @Test func aCloserWithNoOpenerMatchesNothing() {
        #expect(pair("let a = 1 }", caret: 10) == nil)
    }

    /// The case a depth counter gets wrong, and the reason the walk keeps a
    /// stack: counting one kind of bracket would pair this `(` with this `)`
    /// and box two brackets that do not belong to each other.
    @Test func crossedPairsMatchNothing() {
        #expect(pair("([)]", caret: 0) == nil)
        #expect(pair("([)]", caret: 1) == nil)
    }

    // MARK: - The bound

    /// The scan walks outwards from the caret with a limit rather than over
    /// the document, because it runs on every caret move. Past the limit the
    /// answer is no highlight — not a pause.
    @Test func aPartnerBeyondTheLimitIsNotFound() {
        let source = "(" + String(repeating: " ", count: 100) + ")"

        #expect(pair(source, caret: 0, limit: 10) == nil)
        #expect(offsets(source, caret: 0, limit: 200) == [0, 101])
    }

    @Test func theBoundAppliesWalkingBackwardsToo() {
        let source = "(" + String(repeating: " ", count: 100) + ")"
        let end = (source as NSString).length

        #expect(pair(source, caret: end, limit: 10) == nil)
        #expect(offsets(source, caret: end, limit: 200) == [0, 101])
    }

    // MARK: - Edges

    /// A caret at either end of the document, and an empty one. All three are
    /// reachable with ⌘↑ and ⌘↓ and none of them may read out of bounds.
    @Test func theEndsOfTheDocumentAreSafe() {
        #expect(pair("", caret: 0) == nil)
        #expect(offsets("()", caret: 0) == [0, 1])
        #expect(offsets("()", caret: 2) == [0, 1])
        #expect(pair("ab", caret: 2) == nil)
    }

    /// The pair always comes back in document order, whichever half the caret
    /// was on — the caller washes both and would otherwise have to sort them.
    @Test func thePairIsAlwaysInDocumentOrder() {
        for caret in 0...3 {
            guard let found = pair("( )", caret: caret) else { continue }
            #expect(found.open.location < found.close.location)
            #expect(found.open.length == 1 && found.close.length == 1)
        }
    }
}
