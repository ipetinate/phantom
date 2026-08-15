import Foundation
@testable import Ghostty
import Testing

/// LSP's twenty-five kinds against the twenty the list draws.
///
/// The numbers here are written as literals rather than derived from the
/// mapping under test, which is the only way this test says anything: they are
/// the protocol's own numbering, and repeating them from the same switch that
/// is being checked would prove the file agrees with itself.
struct CompletionKindMappingTests {
    /// A server that sends no kind still gets a row, and the row still gets a
    /// glyph — the alternative is a blank icon column for one server, which
    /// reads as a theming bug rather than as missing information.
    @Test func anItemWithNoKindIsAWord() {
        #expect(CompletionKindMapping.kind(lsp: nil) == .text)
    }

    /// A number outside the protocol's range is a server ahead of this app
    /// rather than a broken one, and the safe answer is the same as no kind at
    /// all.
    @Test func aKindThisAppDoesNotKnowIsAWordToo() {
        #expect(CompletionKindMapping.kind(lsp: 0) == .text)
        #expect(CompletionKindMapping.kind(lsp: 26) == .text)
        #expect(CompletionKindMapping.kind(lsp: -1) == .text)
    }

    /// The everyday ones, at the numbers the specification gives them. An
    /// off-by-one in this table draws every row with its neighbour's icon,
    /// which is the kind of wrong that looks deliberate.
    @Test func theCommonKindsLandWhereTheSpecificationPutsThem() {
        #expect(CompletionKindMapping.kind(lsp: 1) == .text)
        #expect(CompletionKindMapping.kind(lsp: 2) == .method)
        #expect(CompletionKindMapping.kind(lsp: 3) == .function)
        #expect(CompletionKindMapping.kind(lsp: 6) == .variable)
        #expect(CompletionKindMapping.kind(lsp: 7) == .type)
        #expect(CompletionKindMapping.kind(lsp: 14) == .keyword)
        #expect(CompletionKindMapping.kind(lsp: 15) == .snippet)
        #expect(CompletionKindMapping.kind(lsp: 17) == .file)
        #expect(CompletionKindMapping.kind(lsp: 21) == .constant)
    }

    /// The three kinds added for the type family, each of which exists because
    /// it changes the glyph.
    @Test func theTypeFamilyKeepsItsDistinctions() {
        #expect(CompletionKindMapping.kind(lsp: 8) == .interface)
        #expect(CompletionKindMapping.kind(lsp: 22) == .structure)
        #expect(CompletionKindMapping.kind(lsp: 13) == .enumeration)
        #expect(CompletionKindMapping.kind(lsp: 20) == .enumCase)
    }

    /// `Field` is `Property` spelled by a different server — TypeScript says
    /// one about a class member, Kotlin says the other about the same member.
    /// Splitting them would draw a distinction between two language servers.
    @Test func aFieldAndAPropertyAreTheSameRow() {
        #expect(CompletionKindMapping.kind(lsp: 5) == .property)
        #expect(CompletionKindMapping.kind(lsp: 10) == .property)
    }

    /// A constructor is the method you call to get one.
    @Test func aConstructorIsAMethod() {
        #expect(CompletionKindMapping.kind(lsp: 4) == .method)
    }

    /// `Unit` and `Color` come from the CSS server, and what makes them legible
    /// in VS Code is a swatch this row cannot draw. Without it, `px` and
    /// `rebeccapurple` are values.
    @Test func theCssKindsAreValues() {
        #expect(CompletionKindMapping.kind(lsp: 11) == .value)
        #expect(CompletionKindMapping.kind(lsp: 12) == .value)
        #expect(CompletionKindMapping.kind(lsp: 16) == .value)
    }

    /// A folder is a path and a path is a string, which is the same rule that
    /// puts `file` in the string colour rather than inventing one for it.
    @Test func aFolderIsAPathLikeAFileIs() {
        #expect(CompletionKindMapping.kind(lsp: 19) == .file)
    }

    /// An operator belongs to the grammar rather than to the file's
    /// vocabulary, and a type parameter is a type at every use site — neither
    /// earns a case of its own.
    @Test func theTwoFoldedTailKindsLandSomewhereHonest() {
        #expect(CompletionKindMapping.kind(lsp: 24) == .keyword)
        #expect(CompletionKindMapping.kind(lsp: 25) == .type)
    }

    /// The one markup kind a language server can actually say. The other three
    /// — tag, attribute, attribute value — arrive from the buffer's own markup
    /// scanner, because the HTML and Vue servers spend LSP's generic kinds on
    /// them (`Property` for a tag, `Value` for an attribute) and nothing in
    /// the integer distinguishes those from a real property.
    @Test func eventIsTheOneMarkupKindTheProtocolNames() {
        #expect(CompletionKindMapping.kind(lsp: 23) == .event)
    }

    /// Every one of the protocol's twenty-five resolves to something, and none
    /// of them falls through to the unknown case by accident — a gap here is a
    /// row that silently claims to be a bare word.
    @Test func everyKindTheProtocolDefinesIsMappedDeliberately() {
        var wordsByAccident: [Int] = []
        for raw in 2...25 where CompletionKindMapping.kind(lsp: raw) == .text {
            wordsByAccident.append(raw)
        }

        #expect(wordsByAccident.isEmpty, "these fell through to the unknown case: \(wordsByAccident)")
    }
}
