import Foundation

/// A ROS 2 message type that can travel over rosbridge as JSON.
///
/// Swift properties are camelCase; the wire keys are snake_case and converted by `ROSJSON`.
public protocol ROSMessage: Codable, Sendable, Equatable {
    /// Fully-qualified ROS 2 type, e.g. `sensor_msgs/msg/JointState`.
    static var rosType: String { get }
}

/// JSON coders configured for rosbridge's wire format (snake_case keys, no key sorting).
public enum ROSJSON {
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try makeEncoder().encode(value)
    }
}
