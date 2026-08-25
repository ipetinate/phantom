import Foundation
import Testing

@testable import Ghostty

/// The JSON-RPC layer, which is the only thing between a line off a socket
/// and a tool call.
@MainActor
struct MCPMessageTests {
    private func line(_ text: String) -> Data { Data(text.utf8) }

    @Test func aRequestIsRead() throws {
        let parsed = MCPMessage.parse(
            line: line(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))

        let request = try #require(try? parsed.get())
        #expect(request.method == "tools/list")
        #expect(request.id == .number(1))
        #expect(!request.isNotification)
    }

    /// The specification allows either, and a client that sends a string id
    /// must get a string id back — matching them is how it pairs an answer to
    /// what it asked.
    @Test func anIdCanBeAStringOrANumber() throws {
        let parsed = MCPMessage.parse(
            line: line(#"{"id":"abc","method":"ping"}"#))
        let request = try #require(try? parsed.get())
        #expect(request.id == .string("abc"))
    }

    /// A notification carries no id and must not be answered at all.
    /// Answering one leaves the client waiting for a response to something it
    /// never asked for.
    @Test func aRequestWithNoIdIsANotification() throws {
        let parsed = MCPMessage.parse(
            line: line(#"{"method":"notifications/initialized"}"#))
        let request = try #require(try? parsed.get())
        #expect(request.isNotification)
    }

    @Test func rubbishIsRefusedAsAParseError() {
        guard case .failure(let refusal) = MCPMessage.parse(line: line("not json")) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.failure.code == -32700)
        #expect(refusal.id == nil)
    }

    /// The id travels with the refusal wherever there is one, so a client can
    /// still match the error to the call it made.
    @Test func aRefusalKeepsTheIdWhenThereIsOne() {
        guard case .failure(let refusal) = MCPMessage.parse(line: line(#"{"id":7}"#)) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.id == .number(7))
        #expect(refusal.failure.code == -32600)
    }

    /// One message per line is the whole framing, so a payload that carried a
    /// newline would end its own message early.
    @Test func anAnswerIsOneLine() throws {
        let data = try #require(MCPMessage.response(
            id: .number(1), result: .object(["text": .string("a\nb")])))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\n"))
    }

    @Test func anErrorCarriesItsCodeAndMessage() throws {
        let data = try #require(MCPMessage.response(
            id: .number(2), failure: .methodNotFound("no such thing")))
        let value = try JSONValue(data: data)
        let error = try #require(value.object?["error"]?.object)
        #expect(error["code"]?.int == -32601)
        #expect(error["message"]?.string == "no such thing")
    }

    // MARK: The service

    @Test func initializeAnnouncesTheServer() throws {
        let request = MCPMessage.Request(id: .number(1), method: "initialize", params: [:])
        let result = try MCPService().answer(request).get()

        #expect(result.object?["serverInfo"]?.object?["name"]?.string == "phantom")
        #expect(result.object?["protocolVersion"]?.string == MCPService.protocolVersion)
    }

    /// Empty in the first cut — the transport, the caller's identity and the
    /// permission model landed before anything could be read or run, because
    /// fitting consent around finished tools is how consent becomes
    /// decoration. Now that the tools exist, what is asserted is that
    /// `tools/list` answers with the registry rather than with a list of its
    /// own: a tool the registry holds and the listing drops is a tool no
    /// client can call.
    @Test func toolsListAnswersWithTheRegistry() throws {
        let request = MCPMessage.Request(id: .number(1), method: "tools/list", params: [:])
        let result = try MCPService().answer(request).get()

        let listed = result.object?["tools"]?.array?.compactMap { $0.object?["name"]?.string }
        #expect(listed == MCPToolRegistry.all.map(\.tool.name))
    }

    /// Every tool is announced with a name, a sentence for the model and a
    /// schema. A tool missing any of the three is one a client cannot call:
    /// the name is how it is reached, the description is what decides whether
    /// it is reached at the right moment, and the schema is what its
    /// arguments are validated against.
    @Test func everyToolIsAnnouncedWithWhatAClientNeeds() throws {
        let request = MCPMessage.Request(id: .number(1), method: "tools/list", params: [:])
        let result = try MCPService().answer(request).get()
        let tools = try #require(result.object?["tools"]?.array)

        #expect(!tools.isEmpty)

        for tool in tools {
            let object = try #require(tool.object)
            #expect(object["name"]?.string?.isEmpty == false)
            #expect(object["description"]?.string?.isEmpty == false)
            #expect(object["inputSchema"]?.object?["type"]?.string == "object")
        }
    }

    /// Two tools with one name is a call that reaches whichever came first in
    /// the registry, which is a coin toss wearing a list.
    @Test func noTwoToolsShareAName() throws {
        let names = MCPService().tools.map(\.name)
        #expect(Set(names).count == names.count)    }

    @Test func anUnknownMethodIsRefusedByName() {
        let request = MCPMessage.Request(id: .number(1), method: "sorcery", params: [:])
        guard case .failure(let failure) = MCPService().answer(request) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.code == -32601)
        #expect(failure.message.contains("sorcery"))
    }

    /// Asked of `call` rather than of `answer`. `answer` refuses every
    /// `tools/call` alike — it returns a value, and a tool may have to wait
    /// for the reader — so a name checked there is only ever the same sentence
    /// about asynchrony, whether the tool exists or not.
    @Test func callingAToolThatDoesNotExistSaysWhichOne() {
        let request = MCPMessage.Request(
            id: .number(1), method: "tools/call", params: ["name": .string("sorcery")])

        var refusal: MCPMessage.Failure?
        MCPService().call(request, context: { _, arguments in
            MCPToolContext(
                callerSurface: nil,
                clientName: nil,
                client: ObjectIdentifier(MCPPermissionStore.shared),
                arguments: arguments)
        }, then: { result in
            if case .failure(let failure) = result { refusal = failure }
        })

        #expect(refusal?.code == -32601)
        #expect(refusal?.message.contains("sorcery") == true)
    }
}
