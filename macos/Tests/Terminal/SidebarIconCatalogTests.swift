import AppKit
@testable import Ghostty
import Testing

/// The shipped SF Symbols list and the search over it.
///
/// The list is generated, so what is worth testing is not its contents but
/// its two promises: every name in it draws, and a query finds a name by any
/// component of its dotted path.
struct SidebarIconCatalogTests {
    /// The reason the list is generated and validated rather than typed. An
    /// unknown name draws nothing at all — not a placeholder, an empty cell —
    /// and the reader cannot tell that from a broken sheet.
    ///
    /// Slow on purpose: it asks AppKit about every shipped name. It is the
    /// only guard against a hand-edit putting a typo in the catalogue.
    @Test func everyShippedNameDraws() {
        let undrawable = SidebarIconCatalog.all.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }

        #expect(undrawable.isEmpty, "\(undrawable.prefix(10)) draw nothing")
    }

    /// A literal split at runtime is one typo away from a leading space or a
    /// blank line becoming a symbol name.
    ///
    /// The count is pinned rather than bounded because the list is generated:
    /// its own header states 4173 in three places, and a regeneration that
    /// changes the number is a change somebody should look at rather than one
    /// that slides through.
    @Test func theListIsCleanAndWithoutRepeats() {
        #expect(SidebarIconCatalog.all.count == 4173)
        #expect(Set(SidebarIconCatalog.all).count == SidebarIconCatalog.all.count)
        #expect(!SidebarIconCatalog.all.contains { $0.isEmpty })
        #expect(!SidebarIconCatalog.all.contains { $0 != $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The names the picker already offers have to be findable in the
    /// browser too, or the two lists disagree about what exists.
    @Test func theCuratedFavouritesAreInTheCatalogue() {
        for symbol in ["folder", "terminal", "flame", "gearshape", "curlybraces", "network"] {
            #expect(SidebarIconCatalog.all.contains(symbol), "\(symbol) is missing")
        }
    }

    /// A dotted name has to be findable by any of its parts, because the
    /// reader remembers the picture, not Apple's word order.
    @Test func anyComponentFindsTheName() {
        #expect(SidebarIconCatalog.matches("arrow").contains("arrow.up.circle"))
        #expect(SidebarIconCatalog.matches("circle").contains("arrow.up.circle"))
        #expect(SidebarIconCatalog.matches("up").contains("arrow.up.circle"))
    }

    /// Several tokens narrow rather than widen, and the separators of a
    /// symbol name count as spaces so a pasted name searches as itself.
    @Test func everyTokenHasToMatch() {
        #expect(SidebarIconCatalog.matches("arrow circle").contains("arrow.up.circle"))
        #expect(SidebarIconCatalog.matches("arrow.up.circle").contains("arrow.up.circle"))
        #expect(SidebarIconCatalog.matches("arrow trash").isEmpty)
    }

    @Test func caseDoesNotMatter() {
        #expect(SidebarIconCatalog.matches("FOLDER") == SidebarIconCatalog.matches("folder"))
    }

    /// Substring matching is generous — "cup" and "group" both contain "up" —
    /// so the results are ordered instead of narrowed. A name whose component
    /// *is* the query comes first.
    @Test func anExactComponentOutranksABuriedMatch() throws {
        let results = SidebarIconCatalog.matches("up")
        let exact = try #require(results.firstIndex(of: "arrow.up"))
        let buried = try #require(results.firstIndex(of: "cup.and.saucer"))

        #expect(exact < buried)
    }

    /// An empty field shows the whole catalogue rather than nothing, so the
    /// browser opens with something to look at.
    @Test func anEmptyQueryKeepsEverything() {
        #expect(SidebarIconCatalog.matches("") == SidebarIconCatalog.all)
        #expect(SidebarIconCatalog.matches("   ") == SidebarIconCatalog.all)
    }

    @Test func nonsenseFindsNothing() {
        #expect(SidebarIconCatalog.matches("zzqqx").isEmpty)
    }
}
