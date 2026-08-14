import Foundation
@testable import Ghostty
import Testing

/// The no-server fallback: identifiers scraped out of the buffer.
struct CodeWordIndexTests {
    private let source = """
    let alpha = 1
    let apple = 2
    func applyIt() {}
    const aardvark = 3
    """

    private var text: NSString { source as NSString }

    private func caretAt(_ needle: String) -> NSRange {
        text.range(of: needle)
    }

    private func words(prefix: String, excluding: NSRange, limit: Int = 20) -> [String] {
        CodeWordIndex.words(in: text, excluding: excluding, matching: prefix, limit: limit)
    }

    // MARK: - What it finds

    @Test func itFindsIdentifiersSharingThePrefix() {
        let found = words(prefix: "ap", excluding: NSRange(location: text.length, length: 0))

        #expect(Set(found) == ["apple", "applyIt"])
    }

    @Test func thePrefixIsMatchedCaseInsensitively() {
        #expect(words(prefix: "AL", excluding: NSRange(location: 0, length: 0)) == ["alpha"])
    }

    /// An empty prefix is a real query — ⌃Space between tokens — and has to
    /// return the neighbourhood rather than nothing.
    @Test func anEmptyPrefixReturnsEverythingNearby() {
        let found = words(prefix: "", excluding: caretAt("applyIt"), limit: 3)

        #expect(found.count == 3)
        #expect(!found.contains("applyIt"))
    }

    @Test func numbersAreNotIdentifiers() {
        #expect(words(prefix: "1", excluding: NSRange(location: 0, length: 0)).isEmpty)
    }

    @Test func aWordIsOfferedOnlyOnce() {
        let repeated = "total total total tot" as NSString
        let typing = NSRange(location: repeated.length - 3, length: 3)
        let found = CodeWordIndex.words(in: repeated, excluding: typing, matching: "tot", limit: 20)

        #expect(found == ["total"])
    }

    // MARK: - The word being typed

    /// The word under the caret matches its own prefix perfectly, so without
    /// this exclusion the list's best suggestion is always the thing you are
    /// halfway through writing.
    @Test func theWordBeingTypedIsNotOfferedBack() {
        let buffer = "connect\nconnectionPool\ncon" as NSString
        let typing = NSRange(location: buffer.length - 3, length: 3)
        let found = CodeWordIndex.words(in: buffer, excluding: typing, matching: "con", limit: 20)

        #expect(!found.contains("con"))
        #expect(Set(found) == ["connect", "connectionPool"])
    }

    /// Taken as a *range* rather than as a string, which matters when the caret
    /// is in the middle of a word: the prefix is `con` but the word in the
    /// buffer is `connect`, and it is the whole word that has to be excluded.
    @Test func aWordTheCaretSitsInsideIsExcludedWhole() {
        let buffer = "container\nconnect" as NSString
        let midWord = NSRange(location: buffer.length - 7, length: 3)
        let found = CodeWordIndex.words(in: buffer, excluding: midWord, matching: "con", limit: 20)

        #expect(found == ["container"])
    }

    // MARK: - Ordering and the cap

    /// Nearest to the caret first, and this is what makes `limit` sane: the cap
    /// has to fall on the words least likely to be wanted. In document order it
    /// would fall on the nearest ones instead — the scan window starts a hundred
    /// kilobytes *above* the caret, so document order hands back the top of the
    /// file and drops what is under your hands.
    @Test func theNearestWordsComeFirst() {
        let found = words(prefix: "a", excluding: caretAt("applyIt"))

        #expect(found == ["apple", "aardvark", "alpha"])
    }

    @Test func theCapIsHonoured() {
        #expect(words(prefix: "a", excluding: caretAt("applyIt"), limit: 2) == ["apple", "aardvark"])
        #expect(words(prefix: "a", excluding: caretAt("applyIt"), limit: 0).isEmpty)
    }

    // MARK: - The scan budget

    /// The reason this is bounded at all: a full scan on every keystroke is
    /// exactly the cost this editor's architecture exists to avoid, and on a
    /// generated module interface — tens of thousands of lines, which is
    /// precisely where go-to-definition lands — it is the pause between typing a
    /// letter and seeing it.
    ///
    /// The same word is found when the file is small, so this is testing the
    /// window rather than the pattern.
    @Test func aWordBeyondTheScanWindowIsNotFound() {
        let filler = String(repeating: "zz\n", count: CodeWordIndex.scanBudget)
        let far = ("distinctiveMarker\n" + filler + "nearWord con") as NSString
        let typing = NSRange(location: far.length - 3, length: 3)

        #expect(far.length > CodeWordIndex.scanBudget)
        #expect(
            CodeWordIndex.words(in: far, excluding: typing, matching: "dis", limit: 20).isEmpty,
            "a word a hundred kilobytes above the caret is outside the window"
        )
        #expect(
            CodeWordIndex.words(in: far, excluding: typing, matching: "near", limit: 20)
                == ["nearWord"]
        )

        let near = "distinctiveMarker nearWord con" as NSString
        #expect(
            CodeWordIndex.words(
                in: near,
                excluding: NSRange(location: near.length - 3, length: 3),
                matching: "dis",
                limit: 20
            ) == ["distinctiveMarker"]
        )
    }

    @Test func anEmptyBufferYieldsNothing() {
        #expect(
            CodeWordIndex.words(
                in: "" as NSString,
                excluding: NSRange(location: 0, length: 0),
                matching: "a",
                limit: 20
            ).isEmpty
        )
    }
}
