import Foundation

/// What the app answers to a client's requests.
///
/// The whole of MCP that matters here is three methods: the client says hello
/// with `initialize`, asks what there is with `tools/list`, and runs one with
/// `tools/call`. Everything else in the specification is optional and this app
/// declares none of it.
///
/// A value with no connection in it, so every answer is testable without a
/// socket — which is the point of the split: the socket is the part that
/// cannot be tested, so it is kept as thin as it can be.
@MainActor
struct MCPService {
    /// What the app calls itself to a client. The name reaches the reader in
    /// their agent's own listing of servers, so it is the app's name and not
    /// an internal one.
    static let serverName = "phantom"

    /// The revision of MCP this speaks. Sent back in `initialize`; a client
    /// asking for another one is answered with this rather than refused,
    /// which is what the specification asks for.
    static let protocolVersion = "2025-06-18"

    /// The tools on offer, assembled from the files that own them.
    ///
    /// A list rather than a type hierarchy: a tool is declared beside the
    /// thing it operates on, and adding one is a line here.
    var handlers: [MCPToolHandler] = MCPToolRegistry.all

    var tools: [MCPTool] { handlers.map(\.tool) }

    /// Read from the bundle rather than written down, for the reason
    /// `appDisplayName` is: a version spelled here would go stale the first
    /// time the real one moved.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Runs a tool, which is the one method that cannot answer immediately:
    /// a tool may have to put a question in front of the reader first.
    func call(
        _ request: MCPMessage.Request,
        context: (String, [String: JSONValue]) -> MCPToolContext,
        then answer: @escaping (Result<JSONValue, MCPMessage.Failure>) -> Void
    ) {
        guard let name = request.params["name"]?.string else {
            return answer(.failure(.invalidParams("A call must name a tool.")))
        }

        guard let handler = handlers.first(where: { $0.tool.name == name }) else {
            return answer(.failure(.methodNotFound("Phantom has no tool called \(name).")))
        }

        var arguments: [String: JSONValue] = [:]
        if case .object(let given)? = request.params["arguments"] { arguments = given }

        handler.run(context(name, arguments)) { result in
            answer(.success(result.value))
        }
    }

    func answer(_ request: MCPMessage.Request) -> Result<JSONValue, MCPMessage.Failure> {
        switch request.method {
        case "initialize":
            return .success(.object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string(Self.appVersion),
                ]),
            ]))

        case "notifications/initialized", "ping":
            return .success(.object([:]))

        case "tools/list":
            return .success(.object(["tools": .array(tools.map(\.json))]))

        case "tools/call":
            /// Answered by `call`, not here: a tool may have to ask the reader
            /// first, and this returns a value.
            return .failure(.internalError("tools/call is answered asynchronously."))

        default:
            return .failure(.methodNotFound("Phantom does not answer \(request.method)."))
        }
    }
}

/// One tool, as MCP describes it: a name, a sentence for the model, and a
/// JSON Schema for its arguments.
struct MCPTool: Equatable {
    var name: String

    /// Written for the model rather than for the reader. It is the only thing
    /// deciding whether a tool is reached for at the right moment, so it says
    /// when to use it, not only what it does.
    var description: String

    /// The argument schema, as a JSON Schema object.
    var schema: JSONValue

    var json: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": schema,
        ])
    }
}
