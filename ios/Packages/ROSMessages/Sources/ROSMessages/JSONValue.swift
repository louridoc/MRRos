import Foundation

/// A dynamically-typed JSON tree. Used where rosbridge carries a payload whose concrete
/// message type is only known by the subscriber (`msg`, `args`, `values`).
public indirect enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    // MARK: Convenience accessors

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self {
            return o[key]
        }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self {
            return s
        }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(n) = self {
            return n
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self {
            return b
        }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self {
            return a
        }
        return nil
    }

    /// Re-decode this subtree as a concrete `Decodable` using rosbridge key conventions.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try ROSJSON.decode(type, from: data)
    }

    /// Build a `JSONValue` from any `Encodable` (keys converted to snake_case).
    public static func from(_ value: some Encodable) throws -> JSONValue {
        let data = try ROSJSON.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
