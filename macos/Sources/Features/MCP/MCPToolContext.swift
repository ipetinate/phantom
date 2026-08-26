import Foundation

/// Everything a tool is told about the call it is answering.
///
/// Carries the caller's identity as the *app* established it, never as the
/// client claimed it — see `MCPHandshake`. A tool that needs to know which
/// terminal is asking reads it here and nowhere else.
@MainActor
struct MCPToolContext {
    /// The tab the caller is sitting in, or nil when it is not one of ours.
    /// An agent in somebody else's terminal can still ask questions that need
    /// no tab; it is the tools that decide which.
    var callerSurface: UUID?

    /// What the client called itself, for the permission sheet. Untrusted: it
    /// names the caller to the reader and decides nothing.
    var clientName: String?

    /// The connection, so a grant given for one call belongs to it and dies
    /// with it.
    var client: ObjectIdentifier

    var arguments: [String: JSONValue]

    func string(_ name: String) -> String? { arguments[name]?.string }
    func int(_ name: String) -> Int? { arguments[name]?.int }
    func bool(_ name: String) -> Bool? { arguments[name]?.bool }

    /// A tab named by argument, parsed. Tools take tab ids as strings because
    /// that is what they handed out in `list_terminals`.
    func surface(_ name: String) -> UUID? {
        string(name).flatMap(UUID.init(uuidString:))
    }
}

/// What a tool answers with.
///
/// MCP wraps every result in content blocks; this app answers with one, and
/// it is either text or a refusal. `isError` is how MCP says "the tool ran and
/// said no", which is different from the protocol-level failures in
/// `MCPMessage.Failure` — a refused permission is the tool speaking, not the
/// transport.
enum MCPToolResult {
    case text(String)
    case json(JSONValue)
    case refused(String)

    var value: JSONValue {
        switch self {
        case .text(let text):
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ])

        case .json(let payload):
            let text = (try? payload.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": payload,
            ])

        case .refused(let reason):
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string(reason)])]),
                "isError": .bool(true),
            ])
        }
    }
}

/// One tool the app offers: what it is called, what it is for, what it takes,
/// and what it does.
///
/// A value rather than a protocol, so a tool is declared beside the thing it
/// operates on and the registry is a list rather than a type hierarchy.
@MainActor
struct MCPToolHandler {
    var tool: MCPTool

    /// Answered asynchronously because a tool may have to ask the reader
    /// first, and the sheet takes as long as it takes.
    var run: (MCPToolContext, @escaping (MCPToolResult) -> Void) -> Void
}

/// A small helper for the schema every tool has to write out.
enum MCPSchema {
    static func object(
        _ properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func enumeration(_ description: String, _ cases: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(cases.map { .string($0) }),
        ])
    }
}
