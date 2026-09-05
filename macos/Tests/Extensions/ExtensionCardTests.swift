import Foundation
@testable import Ghostty
import Testing

struct ExtensionCardTests {
    static var lua: [String: Any] {
        [
            "title": "Lua",
            "tagline": "Highlighting, lua-language-server and StyLua.",
            "author": ["name": "Isac Petinate", "url": "https://github.com/ipetinate"],
            "license": "MIT",
            "created": "2026-09-01",
            "updated": "2026-09-05T04:18:54Z",
            "icon": "media/icon.svg",
            "cover": "media/cover.png",
            "tags": ["lua", "scripting"],
            "screenshots": ["media/a.png", "media/b.gif"],
            "document": "extension.mdx",
            "documentBytes": 4821,
            "media": [
                ["path": "media/icon.svg", "bytes": 1200],
                ["path": "media/cover.png", "bytes": 182_034],
                ["path": "media/a.png", "bytes": 90_000],
                ["path": "media/b.gif", "bytes": 400_000],
            ],
            "mediaBytes": 673_234,
        ]
    }

    static func card(_ changes: [String: Any?]) -> [String: Any] {
        var json = lua
        for (key, value) in changes {
            if let value { json[key] = value } else { json.removeValue(forKey: key) }
        }
        return json
    }

    @Test func readsTheRegistrysOwnShape() throws {
        let card = try #require(ExtensionCard.parse(Self.lua))

        #expect(card.title == "Lua")
        #expect(card.tagline == "Highlighting, lua-language-server and StyLua.")
        #expect(card.author.name == "Isac Petinate")
        #expect(card.author.url?.absoluteString == "https://github.com/ipetinate")
        #expect(card.license == "MIT")
        #expect(card.created == Date(timeIntervalSince1970: 1_788_220_800))
        #expect(card.updated == Date(timeIntervalSince1970: 1_788_581_934))
        #expect(card.icon == "media/icon.svg")
        #expect(card.cover == "media/cover.png")
        #expect(card.tags == ["lua", "scripting"])
        #expect(card.screenshots == ["media/a.png", "media/b.gif"])
        #expect(card.document == "extension.mdx")
        #expect(card.documentBytes == 4821)
        #expect(card.media.count == 4)
        #expect(card.media[1] == ExtensionCard.Media(path: "media/cover.png", bytes: 182_034))
        #expect(card.mediaBytes == 673_234)
    }

    @Test func theOptionalFieldsMayBeAbsent() throws {
        let sparse = Self.card([
            "tagline": nil, "license": nil, "updated": nil, "icon": nil, "cover": nil,
            "tags": nil, "screenshots": nil, "media": nil, "mediaBytes": 0,
        ])
        let card = try #require(ExtensionCard.parse(sparse))

        #expect(card.tagline == "")
        #expect(card.license == "")
        #expect(card.updated == nil)
        #expect(card.icon == nil)
        #expect(card.cover == nil)
        #expect(card.tags.isEmpty)
        #expect(card.screenshots.isEmpty)
        #expect(card.media.isEmpty)
        #expect(card.mediaBytes == 0)
    }

    @Test func aMissingOrMisshapenRequiredFieldIsNoCard() {
        let cases: [[String: Any?]] = [
            ["title": nil], ["title": ""], ["title": 3],
            ["author": nil], ["author": "someone"], ["author": ["url": "https://x.y"]],
            ["created": nil], ["created": "yesterday"],
            ["document": nil], ["document": "README.mdx"], ["document": "docs/extension.mdx"],
            ["documentBytes": nil], ["documentBytes": 0], ["documentBytes": ExtensionMediaGate.maxDocumentBytes + 1],
            ["documentBytes": "4821"], ["documentBytes": true],
            ["mediaBytes": nil], ["mediaBytes": -1], ["mediaBytes": ExtensionMediaGate.maxTotalBytes + 1],
        ]
        for changes in cases {
            #expect(ExtensionCard.parse(Self.card(changes)) == nil, "\(changes)")
        }
    }

    @Test func aPathThatCouldLeaveTheExtensionIsNoCard() {
        let paths = ["/etc/passwd", "../cover.png", "media/../cover.png", "media\\cover.png", "~/cover.png",
                     "./media/cover.png", "media/", "", "media/co\u{202E}ver.png"]
        for path in paths {
            #expect(ExtensionCard.parse(Self.card(["cover": path])) == nil, "\(path)")
            #expect(ExtensionCard.parse(Self.card(["screenshots": [path]])) == nil, "\(path)")
            #expect(ExtensionCard.parse(Self.card(["icon": path])) == nil, "\(path)")
            let media: [[String: Any]] = [["path": path, "bytes": 10]]
            #expect(ExtensionCard.parse(Self.card(["media": media])) == nil, "\(path)")
        }
    }

    @Test func relativePathsAreAcceptedAndReturnedAsWritten() {
        #expect(ExtensionCard.relativePath("media/cover.png") == "media/cover.png")
        #expect(ExtensionCard.relativePath("media/nested/deep.webp") == "media/nested/deep.webp")
        #expect(ExtensionCard.relativePath("icons/lua.svg") == "icons/lua.svg")
        #expect(ExtensionCard.relativePath("a/b..c.png") == nil)
        #expect(ExtensionCard.relativePath(String(repeating: "a", count: 300)) == nil)
    }

    @Test func anSVGIsOnlyEverTheIcon() {
        #expect(ExtensionCard.parse(Self.card(["cover": "media/cover.svg"])) == nil)
        #expect(ExtensionCard.parse(Self.card(["screenshots": ["media/shot.svg"]])) == nil)

        let stray: [[String: Any]] = [["path": "media/logo.svg", "bytes": 100]]
        #expect(ExtensionCard.parse(Self.card(["media": stray])) == nil)

        let iconOnly: [[String: Any]] = [["path": "media/icon.svg", "bytes": 100]]
        #expect(ExtensionCard.parse(Self.card(["media": iconOnly])) != nil)
    }

    @Test func anUnknownMediaTypeIsNoCard() {
        let media: [[String: Any]] = [["path": "media/readme.pdf", "bytes": 100]]
        #expect(ExtensionCard.parse(Self.card(["media": media])) == nil)
        #expect(ExtensionCard.parse(Self.card(["cover": "media/cover.bmp"])) == nil)
        #expect(ExtensionCard.parse(Self.card(["icon": "media/icon.ico"])) == nil)
    }

    @Test func aMediaBudgetBreachIsNoCard() {
        let oversized: [[String: Any]] = [["path": "media/cover.png", "bytes": ExtensionMediaGate.maxImageBytes + 1]]
        #expect(ExtensionCard.parse(Self.card(["media": oversized])) == nil)

        let bigGIF: [[String: Any]] = [["path": "media/b.gif", "bytes": ExtensionMediaGate.maxAnimationBytes + 1]]
        #expect(ExtensionCard.parse(Self.card(["media": bigGIF])) == nil)

        let bigVideo: [[String: Any]] = [["path": "media/demo.mp4", "bytes": ExtensionMediaGate.maxVideoBytes + 1]]
        #expect(ExtensionCard.parse(Self.card(["media": bigVideo])) == nil)

        let tooMany: [[String: Any]] = (0..<(ExtensionMediaGate.maxFiles + 1)).map {
            ["path": "media/shot\($0).png", "bytes": 10]
        }
        #expect(ExtensionCard.parse(Self.card(["media": tooMany])) == nil)

        let heavy: [[String: Any]] = (0..<13).map {
            ["path": "media/shot\($0).png", "bytes": ExtensionMediaGate.maxImageBytes]
        }
        #expect(ExtensionCard.parse(Self.card(["media": heavy])) == nil)

        let negative: [[String: Any]] = [["path": "media/cover.png", "bytes": -1]]
        #expect(ExtensionCard.parse(Self.card(["media": negative])) == nil)
    }

    @Test func anInsecureAuthorURLIsDroppedWithoutTheCard() throws {
        let http = Self.card(["author": ["name": "Someone", "url": "http://example.com"]])
        let card = try #require(ExtensionCard.parse(http))
        #expect(card.author.name == "Someone")
        #expect(card.author.url == nil)
    }

    @Test func listsAreCappedAndDeduplicated() throws {
        let tags = (0..<20).map { "tag\($0)" } + ["tag0"]
        let screenshots = (0..<20).map { "media/shot\($0).png" }
        let card = try #require(ExtensionCard.parse(Self.card(["tags": tags, "screenshots": screenshots])))

        #expect(card.tags.count == ExtensionCard.maxTags)
        #expect(card.tags.first == "tag0")
        #expect(card.screenshots.count == ExtensionCard.maxScreenshots)

        let twice = try #require(ExtensionCard.parse(Self.card(["tags": ["lua", "lua", "Lua"]])))
        #expect(twice.tags == ["lua", "Lua"])
    }

    @Test func displayStringsArriveEscaped() throws {
        let hostile = Self.card(["title": "Lua\u{202E}", "tagline": "line\nbreak", "tags": ["bidi\u{202E}"]])
        let card = try #require(ExtensionCard.parse(hostile))

        #expect(!card.title.unicodeScalars.contains("\u{202E}"))
        #expect(!card.tagline.contains("\n"))
        #expect(card.tags == ["bidi\\u{202E}"])
    }

    @Test func createdReadsADayAndUpdatedAnInstant() throws {
        let card = try #require(ExtensionCard.parse(Self.card(["created": "2026-09-05T04:18:54Z", "updated": "2026-09-05"])))
        #expect(card.created == Date(timeIntervalSince1970: 1_788_581_934))
        #expect(card.updated == Date(timeIntervalSince1970: 1_788_566_400))

        let malformed = try #require(ExtensionCard.parse(Self.card(["updated": "soon"])))
        #expect(malformed.updated == nil)
    }

    @Test func anEntryCarriesItsCard() throws {
        var json = ExtensionIndexTests.lua
        json["card"] = Self.lua
        let entry = try #require(ExtensionIndex.Entry.parse(json))

        #expect(entry.card?.title == "Lua")
        #expect(entry.card?.tags == ["lua", "scripting"])
    }

    @Test func aBadCardNeverDropsTheEntry() throws {
        for card in [5, "card", [1, 2], Self.card(["title": nil])] as [Any] {
            var json = ExtensionIndexTests.lua
            json["card"] = card
            let entry = try #require(ExtensionIndex.Entry.parse(json), "\(card)")
            #expect(entry.card == nil, "\(card)")
        }

        let entry = try #require(ExtensionIndex.Entry.parse(ExtensionIndexTests.lua))
        #expect(entry.card == nil)
    }
}
