import Foundation

/// A JSON value, for the places where the shape is not known ahead of time.
///
/// MCP carries tool arguments as free-form JSON, and a request's `id` may be a
/// string or a number — neither can be modelled by a struct with named fields,
/// and `Any` would push the type checking to every call site as a cast that
/// can fail.
///
/// Written here rather than taken from a package. It is sixty lines, and a
/// dependency is a build input to keep, sign and update for the life of the
/// app.
indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encoded without pretty printing and **without sorted keys**, because
    /// the transport is one message per line: a newline inside the payload
    /// would end the message early.
    func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// The convenience the call sites actually want. A wrong type reads as
    /// absent rather than trapping — a client sending a number where a string
    /// belongs gets "missing argument", which is the true thing to say.
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
