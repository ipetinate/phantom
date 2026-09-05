import Foundation
@testable import Ghostty
import Testing

struct ExtensionIndexTests {
    static let luaSHA = "d257a74b8e99edaf61af34d906463c6c441f4d7979133bdb9e006e5a859ae571"

    static var lua: [String: Any] {
        [
            "id": "ipetinate.lua",
            "name": "Lua",
            "version": "1.0.0",
            "publisher": "ipetinate",
            "description": "Lua: highlighting, lua-language-server and StyLua.",
            "homepage": "https://github.com/ipetinate/phantom-extensions/tree/main/extensions/lua",
            "phantom": "0.16.0",
            "contributes": ["languages", "formatters"],
            "languages": ["lua"],
            "download": [
                "url": "https://github.com/ipetinate/phantom-extensions/releases/download/ipetinate.lua-v1.0.0/ipetinate.lua-1.0.0.zip",
                "sha256": luaSHA,
                "bytes": 1065,
            ],
        ]
    }

    static func entry(_ changes: [String: Any?], download: [String: Any?] = [:]) -> [String: Any] {
        var json = lua
        for (key, value) in changes {
            if let value { json[key] = value } else { json.removeValue(forKey: key) }
        }
        var downloadJSON = lua["download"] as? [String: Any] ?? [:]
        for (key, value) in download {
            if let value { downloadJSON[key] = value } else { downloadJSON.removeValue(forKey: key) }
        }
        json["download"] = downloadJSON
        return json
    }

    static func index(schemaVersion: Any = 1, entries: [[String: Any]]) throws -> Data {
        let json: [String: Any] = [
            "schemaVersion": schemaVersion,
            "generatedAt": "2026-09-05T04:19:09Z",
            "repository": "https://github.com/ipetinate/phantom-extensions",
            "extensions": entries,
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func readsTheRegistrysOwnShape() throws {
        let index = try ExtensionIndex.parse(Self.index(entries: [Self.lua]))

        #expect(index.repository?.absoluteString == "https://github.com/ipetinate/phantom-extensions")
        let generated = try #require(index.generatedAt)
        #expect(generated == Date(timeIntervalSince1970: 1_788_581_949))

        let entry = try #require(index.extensions.first)
        #expect(index.extensions.count == 1)
        #expect(entry.id == "ipetinate.lua")
        #expect(entry.name == "Lua")
        #expect(entry.version == "1.0.0")
        #expect(entry.publisher == "ipetinate")
        #expect(entry.summary == "Lua: highlighting, lua-language-server and StyLua.")
        #expect(entry.homepage?.host == "github.com")
        #expect(entry.minimumPhantomVersion == "0.16.0")
        #expect(entry.contributes == ["languages", "formatters"])
        #expect(entry.languages == ["lua"])
        #expect(entry.downloadURL.lastPathComponent == "ipetinate.lua-1.0.0.zip")
        #expect(entry.sha256 == Self.luaSHA)
        #expect(entry.bytes == 1065)
    }

    @Test func refusesAnySchemaVersionButOne() throws {
        for declared in [2, 0, "1", true, 1.5] as [Any] {
            let data = try Self.index(schemaVersion: declared, entries: [Self.lua])
            #expect(throws: ExtensionIndex.ParseError.self, "\(declared)") {
                try ExtensionIndex.parse(data)
            }
        }
    }

    @Test func refusesAnIndexWithoutASchemaVersion() throws {
        let json: [String: Any] = ["extensions": [Self.lua]]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: ExtensionIndex.ParseError.missingSchemaVersion) {
            try ExtensionIndex.parse(data)
        }
    }

    @Test func refusesBytesThatAreNotAJSONObject() {
        #expect(throws: ExtensionIndex.ParseError.notAnObject) {
            try ExtensionIndex.parse(Data("[1, 2]".utf8))
        }
        #expect(throws: ExtensionIndex.ParseError.notAnObject) {
            try ExtensionIndex.parse(Data("not json".utf8))
        }
    }

    @Test func oneBadEntryCostsOnlyItself() throws {
        let broken = Self.entry(["id": "second", "version": "not-a-version"])
        let third = Self.entry(["id": "publisher.third", "name": "Third"])
        let index = try ExtensionIndex.parse(Self.index(entries: [Self.lua, broken, third]))

        #expect(index.extensions.map(\.id) == ["ipetinate.lua", "publisher.third"])
    }

    @Test func dropsAnEntryMissingOrMisshapingARequiredField() throws {
        let cases: [[String: Any?]] = [
            ["id": nil], ["name": nil], ["version": nil], ["publisher": nil], ["download": nil],
            ["id": "bad id"], ["id": "../escape"], ["id": ".hidden"], ["id": "a/b"], ["id": ""],
            ["version": "1.0"], ["version": "v1.0.0"], ["version": "1.0.0-beta"],
            ["name": ""], ["name": 7],
        ]
        for changes in cases {
            let index = try ExtensionIndex.parse(Self.index(entries: [Self.entry(changes)]))
            #expect(index.extensions.isEmpty, "\(changes)")
        }
    }

    @Test func dropsAnEntryWhoseDownloadCannotBeTrusted() throws {
        let cases: [[String: Any?]] = [
            ["url": nil], ["sha256": nil], ["bytes": nil],
            ["url": "http://github.com/x.zip"], ["url": "ftp://github.com/x.zip"], ["url": "file:///tmp/x.zip"],
            ["url": "https:relative"], ["url": "https://github.com/a\u{202E}b.zip"], ["url": ""],
            ["sha256": String(repeating: "a", count: 63)], ["sha256": String(repeating: "a", count: 65)],
            ["sha256": String(repeating: "g", count: 64)], ["sha256": ""],
            ["bytes": 0], ["bytes": -1], ["bytes": true], ["bytes": "1065"], ["bytes": 1.5],
            ["bytes": ExtensionIndex.maxArchiveBytes + 1],
        ]
        for download in cases {
            let index = try ExtensionIndex.parse(Self.index(entries: [Self.entry([:], download: download)]))
            #expect(index.extensions.isEmpty, "\(download)")
        }
    }

    @Test func acceptsAnUppercaseDigestAndKeepsItLowercase() throws {
        let entry = Self.entry([:], download: ["sha256": Self.luaSHA.uppercased()])
        let index = try ExtensionIndex.parse(Self.index(entries: [entry]))
        #expect(index.extensions.first?.sha256 == Self.luaSHA)
    }

    @Test func optionalFieldsDegradeWithoutDroppingTheEntry() throws {
        let sparse = Self.entry([
            "description": nil, "homepage": "ftp://nope", "phantom": "soon",
            "contributes": nil, "languages": ["lua", "Bad Id", "", 3],
        ])
        let index = try ExtensionIndex.parse(Self.index(entries: [sparse]))

        let entry = try #require(index.extensions.first)
        #expect(entry.summary == "")
        #expect(entry.homepage == nil)
        #expect(entry.minimumPhantomVersion == nil)
        #expect(entry.contributes.isEmpty)
        #expect(entry.languages == ["lua"])
    }

    @Test func aRepeatedIdKeepsTheFirstEntry() throws {
        let again = Self.entry(["name": "Lua again", "version": "2.0.0"])
        let index = try ExtensionIndex.parse(Self.index(entries: [Self.lua, again]))

        #expect(index.extensions.count == 1)
        #expect(index.extensions.first?.version == "1.0.0")
    }

    @Test func displayStringsArriveEscaped() throws {
        let hostile = Self.entry(["name": "Lua\u{202E}", "description": "line\nbreak"])
        let index = try ExtensionIndex.parse(Self.index(entries: [hostile]))

        let entry = try #require(index.extensions.first)
        #expect(!entry.name.unicodeScalars.contains("\u{202E}"))
        #expect(!entry.summary.contains("\n"))
    }

    @Test func aMissingOrMalformedGeneratedAtIsNil() throws {
        let json: [String: Any] = ["schemaVersion": 1, "generatedAt": "yesterday", "extensions": []]
        let index = try ExtensionIndex.parse(JSONSerialization.data(withJSONObject: json))
        #expect(index.generatedAt == nil)
        #expect(index.repository == nil)
        #expect(index.extensions.isEmpty)
    }
}
