import Foundation
@testable import Ghostty
import Testing

struct ExtensionListFilterTests {
    private func entry(
        id: String,
        name: String,
        publisher: String = "acme",
        summary: String = "",
        languages: [String] = []
    ) -> ExtensionIndex.Entry {
        ExtensionIndex.Entry(
            id: id,
            name: name,
            version: "1.0.0",
            publisher: publisher,
            summary: summary,
            homepage: nil,
            minimumPhantomVersion: nil,
            contributes: ["languages"],
            languages: languages,
            downloadURL: URL(fileURLWithPath: "/tmp/phantom-extensions/\(id).zip"),
            sha256: "",
            bytes: 0
        )
    }

    private func installed(id: String, name: String) -> InstalledExtension {
        InstalledExtension(
            id: id,
            name: name,
            version: "1.0.0",
            root: URL(fileURLWithPath: "/tmp/phantom-extensions/\(id)")
        )
    }

    private var lua: ExtensionIndex.Entry {
        entry(id: "acme.lua", name: "Lua", summary: "Lua scripts", languages: ["lua"])
    }

    private var zig: ExtensionIndex.Entry {
        entry(id: "acme.zig", name: "Zig", publisher: "ziglings", summary: "The Zig language",
              languages: ["zig"])
    }

    private var elixir: ExtensionIndex.Entry {
        entry(id: "beam.elixir", name: "Elixir", publisher: "beam",
              summary: "Elixir, mix and HEEx templates", languages: ["elixir", "heex"])
    }

    @Test func anEmptyQueryKeepsEveryEntry() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "")
        #expect(sections.entries.map(\.id) == ["beam.elixir", "acme.lua", "acme.zig"])
        #expect(sections.orphans.isEmpty)
    }

    @Test func whitespaceIsNotAQuery() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig], installed: [], query: "   ")
        #expect(sections.entries.map(\.id) == ["acme.lua", "acme.zig"])
    }

    @Test func entriesSortByNameWhateverTheIndexOrder() {
        let names = ["zig", "Elixir", "lua", "Ada"].map { entry(id: "acme.\($0.lowercased())", name: $0) }
        let sections = ExtensionListFilter.sections(entries: names, installed: [], query: "")
        #expect(sections.entries.map(\.name) == ["Ada", "Elixir", "lua", "zig"])
    }

    @Test func entriesWithTheSameNameKeepTheirIndexOrder() {
        let twins = [
            entry(id: "second.lua", name: "Lua"),
            entry(id: "first.lua", name: "Lua"),
            entry(id: "acme.ada", name: "Ada"),
        ]
        let sections = ExtensionListFilter.sections(entries: twins, installed: [], query: "")
        #expect(sections.entries.map(\.id) == ["acme.ada", "second.lua", "first.lua"])
    }

    @Test func aQueryMatchesTheId() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "beam.")
        #expect(sections.entries.map(\.id) == ["beam.elixir"])
    }

    @Test func aQueryMatchesTheName() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "ZIG")
        #expect(sections.entries.map(\.id) == ["acme.zig"])
    }

    @Test func aQueryMatchesThePublisher() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "ziglings")
        #expect(sections.entries.map(\.id) == ["acme.zig"])
    }

    @Test func aQueryMatchesTheSummary() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "templates")
        #expect(sections.entries.map(\.id) == ["beam.elixir"])
    }

    @Test func aQueryMatchesALanguageId() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "heex")
        #expect(sections.entries.map(\.id) == ["beam.elixir"])
    }

    @Test func aQueryMatchesACardTag() {
        var tagged = zig
        tagged.card = ExtensionCard(
            title: "Zig", tagline: "", license: "MIT", author: ExtensionCard.Author(name: "ziglings", url: nil),
            created: Date(timeIntervalSince1970: 0), updated: nil, icon: nil, cover: nil,
            tags: ["systems", "comptime"], screenshots: [], document: "extension.mdx", documentBytes: 1,
            media: [], mediaBytes: 0)
        let sections = ExtensionListFilter.sections(entries: [lua, tagged, elixir], installed: [], query: "comptime")
        #expect(sections.entries.map(\.id) == ["acme.zig"])
        #expect(ExtensionListFilter.sections(entries: [lua, zig, elixir], installed: [], query: "comptime").isEmpty)
    }

    @Test func nothingMatchingIsEmptyRatherThanEverything() {
        let sections = ExtensionListFilter.sections(entries: [lua, zig], installed: [], query: "rust")
        #expect(sections.isEmpty)
    }

    @Test func installedExtensionsMissingFromTheIndexAreOrphans() {
        let onDisk = [
            installed(id: "acme.lua", name: "Lua"),
            installed(id: "acme.rust", name: "Rust"),
            installed(id: "acme.ada", name: "Ada"),
        ]
        let sections = ExtensionListFilter.sections(entries: [lua, zig], installed: onDisk, query: "")
        #expect(sections.entries.map(\.id) == ["acme.lua", "acme.zig"])
        #expect(sections.orphans.map(\.id) == ["acme.ada", "acme.rust"])
    }

    @Test func orphansAnswerTheQueryOnNameAndId() {
        let onDisk = [
            installed(id: "acme.rust", name: "Rust"),
            installed(id: "acme.ada", name: "Ada"),
        ]
        let byName = ExtensionListFilter.sections(entries: [lua], installed: onDisk, query: "rust")
        #expect(byName.entries.isEmpty)
        #expect(byName.orphans.map(\.id) == ["acme.rust"])

        let byId = ExtensionListFilter.sections(entries: [lua], installed: onDisk, query: "acme.ada")
        #expect(byId.orphans.map(\.id) == ["acme.ada"])
    }

    @Test func anEmptyIndexMakesEveryInstalledExtensionAnOrphan() {
        let onDisk = [installed(id: "acme.lua", name: "Lua")]
        let sections = ExtensionListFilter.sections(entries: [], installed: onDisk, query: "")
        #expect(sections.entries.isEmpty)
        #expect(sections.orphans.map(\.id) == ["acme.lua"])
    }

    @Test func contributionChipsNameTheFourKnownKinds() {
        #expect(ExtensionContributionChip.of("languages").title == "Languages")
        #expect(ExtensionContributionChip.of("languages").systemImage == "chevron.left.forwardslash.chevron.right")
        #expect(ExtensionContributionChip.of("formatters").systemImage == "text.alignleft")
        #expect(ExtensionContributionChip.of("themes").systemImage == "paintpalette")
        #expect(ExtensionContributionChip.of("iconThemes") == ExtensionContributionChip(
            title: "Icon Themes", systemImage: "photo.on.rectangle"))
    }

    @Test func anUnknownContributionKeepsItsOwnName() {
        #expect(ExtensionContributionChip.of("snippets") == ExtensionContributionChip(
            title: "snippets", systemImage: "puzzlepiece"))
    }
}
