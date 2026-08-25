import Foundation

/// The JSON-RPC 2.0 shapes MCP is carried in, as values.
///
/// Written out rather than taken from a package: the surface this app answers
/// is small and fixed, and a dependency for four structs would be a build
/// input to keep, sign and update for the rest of the app's life.
///
/// `id` is a JSON value in the specification — a string, a number, or absent
/// for a notification — so it is kept as one rather than forced into a type
/// that would have to guess on the way back out.
enum MCPMessage {
    struct Request: Equatable {
        var id: ID?
        var method: String
        var params: [String: JSONValue]

        /// True when there is no id: a notification, which by the
        /// specification must not be answered at all. Answering one is how a
        /// client ends up waiting for a response to something it never asked.
        var isNotification: Bool { id == nil }
    }

    enum ID: Equatable, Codable {
        case number(Int)
        case string(String)

        init?(_ value: JSONValue) {
            switch value {
            case .number(let number): self = .number(Int(number))
            case .string(let string): self = .string(string)
            default: return nil
            }
        }

        var json: JSONValue {
            switch self {
            case .number(let number): return .number(Double(number))
            case .string(let string): return .string(string)
            }
        }
    }

    /// The errors this app can answer with, with the codes the specification
    /// reserves. `invalidRequest` and `parseError` are the two a malformed
    /// line produces; the rest are ours to raise.
    enum Failure: Equatable, Error {
        case parseError(String)
        case invalidRequest(String)
        case methodNotFound(String)
        case invalidParams(String)
        case internalError(String)

        var code: Int {
            switch self {
            case .parseError: return -32700
            case .invalidRequest: return -32600
            case .methodNotFound: return -32601
            case .invalidParams: return -32602
            case .internalError: return -32603
            }
        }

        var message: String {
            switch self {
            case .parseError(let text),
                 .invalidRequest(let text),
                 .methodNotFound(let text),
                 .invalidParams(let text),
                 .internalError(let text):
                return text
            }
        }
    }

    /// Parses one line into a request.
    ///
    /// A line that is not an object, or has no `method`, is a request this app
    /// refuses rather than guesses at — and the refusal carries the id when
    /// there is one, so the client can match it to what it sent.
    /// A request that could not be read, and the id to answer it with — which
    /// is often absent, because a line that is not JSON has no id to find.
    struct Refusal: Equatable, Error {
        var id: ID?
        var failure: Failure
    }

    static func parse(line: Data) -> Result<Request, Refusal> {
        guard let value = try? JSONValue(data: line) else {
            return .failure(Refusal(id: nil, failure: .parseError("The line is not JSON.")))
        }

        guard case .object(let object) = value else {
            return .failure(Refusal(
                id: nil, failure: .invalidRequest("A request must be a JSON object.")))
        }

        let id = object["id"].flatMap(ID.init)

        guard case .string(let method)? = object["method"] else {
            return .failure(Refusal(
                id: id, failure: .invalidRequest("A request must carry a method.")))
        }

        var params: [String: JSONValue] = [:]
        if case .object(let given)? = object["params"] { params = given }

        return .success(Request(id: id, method: method, params: params))
    }

    static func response(id: ID?, result: JSONValue) -> Data? {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "result": result]
        if let id { object["id"] = id.json } else { object["id"] = .null }
        return try? JSONValue.object(object).data()
    }

    static func response(id: ID?, failure: Failure) -> Data? {
        let error: JSONValue = .object([
            "code": .number(Double(failure.code)),
            "message": .string(failure.message),
        ])

        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "error": error]
        if let id { object["id"] = id.json } else { object["id"] = .null }
        return try? JSONValue.object(object).data()
    }
}
