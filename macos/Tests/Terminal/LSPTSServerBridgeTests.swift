import Foundation
@testable import Ghostty
import Testing

/// The relay that lets a `.vue` template offer a component the file has not
/// imported yet.
///
/// Every shape here was copied from a live `@vue/language-server` 3.3.10 and
/// `typescript-language-server` 5.3.0 talking to each other, because the
/// nesting is the part that has no second chance: read the parameters one
/// level too shallow and the command comes out nil, the relay answers
/// nothing, and the server waits for an answer that never arrives rather
/// than reporting anything.
struct LSPTSServerBridgeTests {
    private func notification(params: LSPValue?) -> LSPNotification {
        LSPNotification(method: LSPTSServerBridge.requestMethod, params: params)
    }

    /// The shape `vscode-jsonrpc` actually sends: the triple wrapped in a
    /// one-element parameter list.
    @Test func aNestedRequestIsRead() throws {
        let sent = notification(params: .array([.array([
            .integer(4),
            .string("_vue:getAutoImportSuggestions"),
            .array([.string("/w/App.vue"), .integer(1185)]),
        ])]))

        let request = try #require(LSPTSServerBridge.request(in: sent))
        #expect(request.id == .integer(4))
        #expect(request.command == "_vue:getAutoImportSuggestions")
        #expect(request.arguments == .array([.string("/w/App.vue"), .integer(1185)]))
    }

    /// The unnested shape too, so the reading does not depend on a
    /// convention the other side could change.
    @Test func aFlatRequestIsReadTheSameWay() throws {
        let sent = notification(params: .array([
            .integer(1),
            .string("_vue:projectInfo"),
            ["file": .string("/w/App.vue")],
        ]))

        let request = try #require(LSPTSServerBridge.request(in: sent))
        #expect(request.command == "_vue:projectInfo")
        #expect(request.arguments == ["file": .string("/w/App.vue")])
    }

    /// A command with no arguments is still a command. Answering nothing
    /// because the third slot was missing is the hang this whole type is
    /// about.
    @Test func aRequestWithoutArgumentsStillReads() throws {
        let sent = notification(params: .array([.array([.integer(9), .string("_vue:getElementNames")])]))

        let request = try #require(LSPTSServerBridge.request(in: sent))
        #expect(request.command == "_vue:getElementNames")
        #expect(request.arguments == .null)
    }

    @Test func anotherNotificationIsNotARequest() {
        let other = LSPNotification(method: "window/logMessage", params: ["message": .string("hi")])
        #expect(LSPTSServerBridge.request(in: other) == nil)
    }

    /// A malformed payload is refused rather than turned into a request with
    /// an empty command — which would be relayed, refused by the wrapper,
    /// and reported as a `tsserver` failure that never happened.
    @Test func aPayloadWithoutACommandIsRefused() {
        #expect(LSPTSServerBridge.request(in: notification(params: .array([.array([.integer(1)])]))) == nil)
        #expect(LSPTSServerBridge.request(in: notification(params: .string("nope"))) == nil)
        #expect(LSPTSServerBridge.request(in: notification(params: nil)) == nil)
    }

    /// The wrapper's command takes the `tsserver` command name, its
    /// arguments, and its own execution options — in that order, positional.
    @Test func theExecuteCommandCarriesTheThreePositionalArguments() throws {
        let request = LSPTSServerBridge.Request(
            id: .integer(2),
            command: "_vue:getComponentNames",
            arguments: .array([.string("/w/App.vue")])
        )

        let params = LSPTSServerBridge.executeCommandParams(for: request)
        #expect(params["command"] == .string("typescript.tsserverRequest"))

        let arguments = try #require(params["arguments"]?.arrayValue)
        #expect(arguments.count == 3)
        #expect(arguments[0] == .string("_vue:getComponentNames"))
        #expect(arguments[1] == .array([.string("/w/App.vue")]))
        #expect(arguments[2]["expectsResult"] == .bool(true))
        #expect(arguments[2]["isAsync"] == .bool(false))
    }

    /// The answer goes back nested the same way it arrived, because the
    /// server destructures its first parameter as the pair.
    @Test func theResponseIsNestedAndKeepsTheServersOwnID() throws {
        let params = LSPTSServerBridge.responseParams(id: .integer(7), body: ["ok": .bool(true)])

        let outer = try #require(params.arrayValue)
        #expect(outer.count == 1)
        let pair = try #require(outer[0].arrayValue)
        #expect(pair[0] == .integer(7))
        #expect(pair[1] == ["ok": .bool(true)])
    }

    /// The wrapper hands back the whole `tsserver` envelope; the server
    /// wants only what is inside it.
    @Test func theBodyIsTakenOutOfTheEnvelope() {
        let envelope: LSPValue = [
            "seq": .integer(0),
            "type": .string("response"),
            "command": .string("_vue:projectInfo"),
            "success": .bool(true),
            "body": ["configFileName": .string("/w/tsconfig.json")],
        ]

        #expect(LSPTSServerBridge.body(of: envelope) == ["configFileName": .string("/w/tsconfig.json")])
    }

    /// A command that failed is reported as nothing rather than as the
    /// envelope. The callers on the other side read the answer's fields
    /// directly, and an envelope satisfies every optional check while being
    /// the wrong object.
    @Test func aFailedCommandBecomesNull() {
        let failed: LSPValue = [
            "success": .bool(false),
            "message": .string("No Project."),
            "body": ["stale": .bool(true)],
        ]

        #expect(LSPTSServerBridge.body(of: failed) == .null)
    }

    /// A reply with no body at all — several `_vue:` commands answer that
    /// way when there is nothing to say.
    @Test func anEmptyBodyBecomesNull() {
        #expect(LSPTSServerBridge.body(of: ["success": .bool(true)]) == .null)
    }

    /// The file a request is about, in both shapes — the object the
    /// commands `tsserver` defines take, and the positional array the
    /// plugin's take.
    @Test func theFileIsFoundInEitherArgumentShape() {
        let object = LSPTSServerBridge.Request(
            id: .integer(1),
            command: "_vue:projectInfo",
            arguments: ["file": .string("/w/App.vue"), "needFileNameList": .bool(false)]
        )
        #expect(LSPTSServerBridge.fileName(in: object) == "/w/App.vue")

        let positional = LSPTSServerBridge.Request(
            id: .integer(2),
            command: "_vue:getAutoImportSuggestions",
            arguments: .array([.string("/w/App.vue"), .integer(1185)])
        )
        #expect(LSPTSServerBridge.fileName(in: positional) == "/w/App.vue")
    }

    /// A command that names no file has none, and the caller must not wait
    /// for a document that was never going to be announced.
    @Test func aRequestWithoutAFileNamesNothing() {
        let bare = LSPTSServerBridge.Request(id: .integer(3), command: "_vue:getElementNames", arguments: .null)
        #expect(LSPTSServerBridge.fileName(in: bare) == nil)
    }
}
