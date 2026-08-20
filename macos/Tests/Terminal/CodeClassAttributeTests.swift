import Foundation
@testable import Ghostty
import Testing

/// Where a class attribute starts and ends, which is the fact the Tailwind
/// completion is built on.
///
/// Every case here is a line somebody actually writes. The ones worth reading
/// are the refusals: a caret in an ordinary string, in a template
/// interpolation, or just outside a closing quote all *look* like they are
/// inside a class attribute to a scanner that only counts quotes, and each of
/// them turning off the string suppression would put a 1-character trigger
/// back into prose.
struct CodeClassAttributeTests {
    private func token(_ line: String, caret: Int? = nil) -> NSRange? {
        let text = line as NSString
        return CodeClassAttribute.tokenRange(in: text, caret: caret ?? text.length)
    }

    private func typed(_ line: String, caret: Int? = nil) -> String? {
        let text = line as NSString
        guard let range = token(line, caret: caret) else { return nil }
        return text.substring(with: range)
    }

    // MARK: - The run being completed

    @Test func readsTheClassUnderTheCaret() {
        #expect(typed(#"<div className="w-"#) == "w-")
    }

    /// The whole reason this type exists rather than reusing the identifier
    /// rule: every one of these is *one* class, and the identifier rule ends
    /// the run at the first character that is not a letter — which for `w-`
    /// is an empty query against eleven thousand candidates.
    @Test(arguments: [
        (#"<div className="w-1/2"#, "w-1/2"),
        (#"<div className="bg-[#fff]"#, "bg-[#fff]"),
        (#"<div className="hover:underline"#, "hover:underline"),
        (#"<div className="[&>*]:mt-2"#, "[&>*]:mt-2"),
        (#"<div className="!p-0"#, "!p-0"),
    ])
    func aClassIsNotAnIdentifier(line: String, expected: String) {
        #expect(typed(line) == expected)
    }

    /// Only the class the caret is in, not the ones before it.
    @Test func stopsAtTheClassBoundary() {
        #expect(typed(#"<div className="flex items-center gap"#) == "gap")
    }

    /// An empty answer is the list opening on everything, which is what typing
    /// the quote should do — so it has to be a range and not a refusal.
    @Test func theEmptyValueIsAnAnswerAndNotARefusal() {
        let range = token(#"<div className=""#)
        #expect(range?.length == 0)
        #expect(range?.location == 16)
    }

    @Test func spaceStartsTheNextClass() {
        #expect(typed(#"<div className="flex "#) == "")
    }

    // MARK: - The dialects

    @Test(arguments: [
        #"<div class="p"#,
        #"<div className="p"#,
        #"<div :class="p"#,
        #"<div v-bind:class="p"#,
        #"<div x-bind:class="p"#,
        #"<div [ngClass]="p"#,
        #"<div class:list="p"#,
        #"<div CLASS="p"#,
    ])
    func everyWayOfSpellingIt(line: String) {
        #expect(typed(line) == "p", "\(line)")
    }

    @Test func singleQuotesAndBackticks() {
        #expect(typed("<div class='p-2") == "p-2")
        #expect(typed("<div className={`p-2") == "p-2")
    }

    // MARK: - The refusals

    /// The case the whole exception is answerable for. If this returned a
    /// range, every string in every React file would complete on one
    /// character.
    @Test func anOrdinaryStringIsNotAClassAttribute() {
        #expect(token(#"const title = "Hello wor"#) == nil)
        #expect(token(#"<div title="a plain sen"#) == nil)
    }

    /// Caret outside the string, one character past its closing quote. The
    /// nearest quote behind it is that closing quote, so a scanner that only
    /// looks for a quote says yes; reading what precedes the quote says no.
    @Test func justOutsideTheValueIsOutside() {
        #expect(token(#"<div className="flex">"#, caret: 21) == nil)
    }

    /// Inside `${…}` the caret is in code, not in a class list — and the
    /// nested string it may be in is somebody's ternary.
    @Test func templateInterpolationIsCode() {
        #expect(token(#"<div className={`p-2 ${ok ? "a"#) == nil)
    }

    /// Vue's object syntax. Tailwind's own server completes here and this
    /// scanner does not — a stated limit rather than an oversight, because
    /// the key is a string whose neighbour is `{` and not `=`.
    @Test func objectSyntaxIsNotHandled() {
        #expect(token(#"<div :class="{ 'p-2"#) == nil)
    }

    @Test func aNewlineEndsTheSearch() {
        #expect(token("<div className=\"flex\n  more-w") == nil)
    }

    @Test func nothingBeforeTheQuoteAtAll() {
        #expect(token(#""w-"#) == nil)
        #expect(token(#"="w-"#) == nil)
    }

    @Test func anAttributeThatMerelyEndsInClass() {
        #expect(token(#"<div superclass="p"#) == nil)
        #expect(token(#"<div data-class="p"#) == nil)
    }

    // MARK: - Bounds

    @Test func caretPastTheEndIsClamped() {
        let text = #"<div class="p"# as NSString
        #expect(CodeClassAttribute.tokenRange(in: text, caret: text.length + 50) != nil)
    }

    @Test func emptyText() {
        #expect(CodeClassAttribute.tokenRange(in: "" as NSString, caret: 0) == nil)
    }

    private func line(classes count: Int) -> NSString {
        let classes = (0..<count).map { "px-\($0) hover:mt-\($0)" }.joined(separator: " ")
        return #"<div className=""# + classes as NSString
    }

    private func perScan(_ line: NSString, iterations: Int = 1000) -> Duration {
        let elapsed = ContinuousClock().measure {
            for _ in 0..<iterations {
                _ = CodeClassAttribute.tokenRange(in: line, caret: line.length)
            }
        }
        return elapsed / iterations
    }

    /// **The cost is linear in the length of the attribute**, because finding
    /// the quote means walking back over every class before the caret. That is
    /// inherent rather than lazy: knowing whether the caret is in a class
    /// attribute at all requires reaching the attribute.
    ///
    /// So the budget is stated at two sizes. A `className` with forty
    /// utilities — long by the standards of real markup — is the one that has
    /// to be free.
    @Test func isFreeOnARealisticAttribute() {
        let each = perScan(line(classes: 20))
        #expect(each < .microseconds(10), "\(each) per scan")
    }

    /// And an absurd one still has to be affordable rather than merely
    /// bounded. Measured at ~56 µs for an 800-class attribute — 0.3% of a
    /// frame, against the ~12 µs the highlighter already spends per keystroke
    /// and the 2.7 ms that got `SFCRegions` ruled out of this path entirely.
    /// The number is here so that a change making it quadratic is loud.
    @Test func staysAffordableOnAnAbsurdAttribute() {
        let each = perScan(line(classes: 400), iterations: 200)
        #expect(each < .microseconds(400), "\(each) per scan")
    }
}
