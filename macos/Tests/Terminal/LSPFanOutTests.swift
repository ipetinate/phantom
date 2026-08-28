import Foundation
@testable import Ghostty
import Testing

/// What counts as an answer when a file has more than one server.
///
/// A `.vue` has two, and they are complementary: measured on this machine
/// (`vue-language-server` 2.2.12, `typescript-language-server` 5.3.0 with
/// `@vue/typescript-plugin` 3.3.10 and TypeScript 6.0.3), hovering inside a
/// `<script setup>` block yields *nothing* from the Vue server and the real
/// type from the TypeScript one, while hovering a `<style>` selector is the
/// other way round. Asking only the primary is why hover was silent in the
/// half of a `.vue` that is written in TypeScript.
///
/// The payloads below are the ones those servers actually sent, not invented
/// shapes — the empty-string case in particular is a shape nobody would
/// think to invent.
struct LSPFanOutAnswerTests {
    /// `textDocument/hover` from `vue-language-server`, asked about
    /// `const count = ref(0)` inside `<script setup>`. A bare null result.
    private let vueInsideScript = LSPValue.null

    /// The same question to `typescript-language-server` for a `.vue`
    /// **without** `@vue/typescript-plugin`. Not null — an empty string,
    /// wrapped in a perfectly well-formed `MarkupContent`.
    private let typeScriptWithoutThePlugin: LSPValue = [
        "contents": ["kind": .string("markdown"), "value": .string("")],
    ]

    /// The same question with the plugin loaded.
    private let typeScriptWithThePlugin: LSPValue = [
        "contents": [
            "kind": .string("markdown"),
            "value": .string("```typescript\nconst count: Ref<number, number>\n```\n"),
        ],
    ]

    /// **The trap this rule exists for.** A server that answers is not a
    /// server that has something to say: a "did the reply arrive" test stops
    /// at the empty string above and the next server is never asked, which is
    /// the same silence as before with more requests behind it.
    @Test func anEmptyReplyIsNotAnAnswerWhicheverShapeItArrivesIn() {
        #expect(LSPCenter.hoverText(from: vueInsideScript["contents"]) == nil)
        #expect(LSPCenter.hoverText(from: typeScriptWithoutThePlugin["contents"]) == nil)
    }

    @Test func aReplyWithContentIsAnAnswer() {
        let text = LSPCenter.hoverText(from: typeScriptWithThePlugin["contents"])
        #expect(text?.contains("const count: Ref<number, number>") == true)
    }

    /// Definition and references ask through the same helper, where "nothing"
    /// arrives as an empty list rather than as a null.
    @Test func anEmptyListIsNotAnAnswerAndANonEmptyOneIsKeptWhole() {
        #expect(LSPCenter.answer([Int]()) == nil)
        #expect(LSPCenter.answer([1, 2]) == [1, 2])
        #expect(LSPCenter.answer(LSPCenter.locations(from: .null)) == nil)
    }

    /// A location list that is real survives the emptiness test, so the fan-out
    /// stops at the server that produced it rather than asking the next.
    @Test func aLocationFromAServerIsAnAnswer() {
        let location: LSPValue = [
            "uri": .string("file:///p/App.vue"),
            "range": [
                "start": ["line": .integer(7), "character": .integer(6)],
                "end": ["line": .integer(7), "character": .integer(11)],
            ],
        ]
        #expect(LSPCenter.answer(LSPCenter.locations(from: location))?.count == 1)
    }
}

/// That the positional features go through the fan-out, read out of the
/// source rather than asserted about.
///
/// The same technique `LanguageTrustGatePlacementTests` uses, and for a
/// reason with a scar behind it: the two-server plumbing was landed once
/// before with `completions()` left on the single-server call, so the whole
/// mechanism existed and the symptom on screen was unchanged. A promise about
/// which helper a call site uses is kept by a test that reads it or not at
/// all — nothing this suite could execute would tell hover-from-one-server
/// apart from hover-from-two on a machine with no language server installed.
struct LSPFanOutPlacementTests {
    private var centerSource: URL {
        URL(fileURLWithPath: #filePath)          // …/macos/Tests/Terminal/<this>.swift
            .deletingLastPathComponent()          // …/macos/Tests/Terminal
            .deletingLastPathComponent()          // …/macos/Tests
            .deletingLastPathComponent()          // …/macos
            .appendingPathComponent("Sources/Features/Terminal/Editor/LSP/LSPCenter.swift")
    }

    /// The file's methods, each as the text from its declaration up to the
    /// next one — split at member indentation, so a nested closure's `func`
    /// stays part of the method that holds it.
    ///
    /// Comments are dropped first, or a doc comment *explaining* the rule
    /// would satisfy it.
    private func methods() throws -> [(name: String, body: String)] {
        let lines = try String(contentsOf: centerSource, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                    && !trimmed.hasPrefix("/*")
            }

        let declaration = try NSRegularExpression(
            pattern: #"^    (?:private |fileprivate |internal |nonisolated |static |final )*"#
                + #"func ([A-Za-z_][A-Za-z0-9_]*)"#
        )

        var found: [(name: String, body: String)] = []
        for line in lines {
            let whole = NSRange(location: 0, length: (line as NSString).length)
            if let match = declaration.firstMatch(in: line, options: [], range: whole),
               let name = Range(match.range(at: 1), in: line) {
                found.append((name: String(line[name]), body: line))
            } else if !found.isEmpty {
                found[found.count - 1].body += "\n" + line
            }
        }
        return found
    }

    /// The body of a method, chosen by name and by the labels that tell two
    /// of them apart.
    ///
    /// `LSPCenter` has two methods called `definition`: the feature, which
    /// takes a position, and `definition(forPath:)`, which looks up a server's
    /// configuration and happens to be declared first. Matching on the name
    /// alone read the wrong one — the test failed while the code was right,
    /// which is the worse of the two ways a source-reading test can be wrong.
    private func body(of name: String, taking label: String? = nil) throws -> String {
        let all = try methods()
        let method = try #require(
            all.first { candidate in
                guard candidate.name == name else { return false }
                guard let label else { return true }
                /// The scanned body starts at the declaration line, so the
                /// parameter labels are in it.
                return candidate.body.contains(label)
            },
            "LSPCenter has no method named \(name)\(label.map { " taking \($0)" } ?? "")"
        )
        return method.body
    }

    /// Guards the guard: a wrong path or a broken split would make everything
    /// below pass by finding nothing.
    @Test func theSourceIsWhereWeThinkItIs() throws {
        let names = try methods().map(\.name)
        #expect(names.contains("firstAnswer"), "no firstAnswer in \(names.count) methods")
        #expect(names.contains("hover"))
    }

    /// **The rule.** Every feature that asks about a position asks each of the
    /// file's servers, not the primary alone.
    @Test func everyPositionalFeatureGoesThroughTheFanOut() throws {
        for feature in ["hover", "definition", "references", "rename"] {
            /// By the position parameter, which is what makes a feature
            /// positional and what separates `definition` from the
            /// server-configuration lookup of the same name.
            let text = try body(of: feature, taking: "position: LSPPosition")
            #expect(
                text.contains("firstAnswer("),
                """
                LSPCenter.\(feature) does not go through firstAnswer, so it asks the \
                primary server alone. In a .vue that is the template server, which \
                answers nothing at all about a <script> block — the feature is silent \
                in half the file and no failure is reported anywhere.
                """
            )
        }
    }

    /// And the fan-out asks *every* server: the plural helper, not the
    /// singular one whose name is one character away.
    @Test func theFanOutAsksEveryServerTheFileHas() throws {
        let fanOut = try body(of: "firstAnswer")
        #expect(fanOut.contains("runningServers(forPath:"))
        #expect(
            !fanOut.contains("runningServer(forPath: path)"),
            "firstAnswer resolved one server, which makes the loop around it decoration"
        )
    }

    /// Formatting is the one feature that asks the file's *primary* server
    /// and no other, so that list staying at one is a decision somebody
    /// makes rather than a drift.
    ///
    /// Formatting is a whole-document rewrite, and two servers' answers
    /// cannot be chosen between — the second would silently overwrite the
    /// first.
    ///
    /// `completionItem/resolve` used to be on this list and no longer is.
    /// That is a tightening, not a loosening: it still speaks to exactly one
    /// server, and it no longer assumes that server is the primary. The rule
    /// moved to `onlyOneServerAnswersAResolveAndItIsTheRightOne` below,
    /// because the property worth guarding was never "it calls the singular
    /// helper" — it was "one request, to the server the item came from".
    @Test func onlyFormattingSpeaksToThePrimaryAlone() throws {
        let singular = try methods()
            .filter { $0.body.contains("runningServer(forPath: path)") }
            .map(\.name)
            .sorted()

        #expect(
            singular == ["formatting"],
            "a feature took the single-server path: \(singular)"
        )
    }

    /// A resolve is about an item **from** a particular server's list and is
    /// meaningless to any other. So it enumerates the file's servers to find
    /// that one, and then asks it alone.
    ///
    /// Measured, which is why narrowing to one is not a style preference: a
    /// `.vue` list is two servers' answers concatenated, and handing
    /// `typescript-language-server`'s item to the Vue server answers
    /// `-32603 Cannot read properties of undefined (reading '1')` — the name
    /// was accepted and its import was never written.
    ///
    /// Asking *every* server would be worse than asking the wrong one. A
    /// server that cannot match an item returns it **unchanged and without
    /// an error**, so a loop would take the first non-answer as the answer
    /// and stop.
    @Test func onlyOneServerAnswersAResolveAndItIsTheRightOne() throws {
        let resolve = try body(of: "performResolve")

        #expect(
            resolve.contains("Self.resolvingCommand(for: item"),
            "performResolve no longer picks the server that made the item"
        )
        #expect(
            resolve.contains("live.first(where:"),
            "performResolve no longer narrows the file's servers down to one"
        )
        #expect(
            !resolve.contains("for (key, server) in live"),
            """
            performResolve loops the request over every server. A server that \
            cannot match an item answers it unchanged rather than failing, so \
            the loop would keep the first non-answer.
            """
        )
    }

    /// A cancelled request is the reader having moved on, and the next server
    /// would be work for an answer nobody is waiting for. Every *other*
    /// failure falls through, so one server being down does not cost the file
    /// the other's answer — the two halves of that are easy to write as one
    /// `return` and lose.
    @Test func theFanOutStopsWhenTheCallerGaveUpAndOnlyThen() throws {
        let fanOut = try body(of: "firstAnswer")
        #expect(fanOut.contains("Task.isCancelled"))
        #expect(fanOut.contains("failure == .cancelled"))
    }
}
