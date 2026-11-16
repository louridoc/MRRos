import Foundation
import ROSMessages

/// Errors surfaced by `RosbridgeClient`.
public enum RosbridgeError: Error, Equatable, Sendable {
    case notConnected
    case connectionClosed
    case transport(String)
    case serviceFailed(service: String, message: String)
    case timeout(String)
    case decoding(String)
}

/// Client → server operations, encoded exactly as the rosbridge v2 protocol expects.
enum OutgoingOp: Encodable, Sendable {
    case subscribe(id: String, topic: String, type: String, throttleRate: Int, queueLength: Int)
    case unsubscribe(id: String, topic: String)
    case advertise(id: String, topic: String, type: String)
    case unadvertise(id: String, topic: String)
    case publish(topic: String, msg: JSONValue)
    case callService(id: String, service: String, type: String?, args: JSONValue?)

    private enum Key: String, CodingKey {
        case op, id, topic, type, msg, service, args
        case throttleRate = "throttle_rate"
        case queueLength = "queue_length"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .subscribe(id, topic, type, throttleRate, queueLength):
            try c.encode("subscribe", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(topic, forKey: .topic)
            try c.encode(type, forKey: .type)
            try c.encode(throttleRate, forKey: .throttleRate)
            try c.encode(queueLength, forKey: .queueLength)
        case let .unsubscribe(id, topic):
            try c.encode("unsubscribe", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(topic, forKey: .topic)
        case let .advertise(id, topic, type):
            try c.encode("advertise", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(topic, forKey: .topic)
            try c.encode(type, forKey: .type)
        case let .unadvertise(id, topic):
            try c.encode("unadvertise", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(topic, forKey: .topic)
        case let .publish(topic, msg):
            try c.encode("publish", forKey: .op)
            try c.encode(topic, forKey: .topic)
            try c.encode(msg, forKey: .msg)
        case let .callService(id, service, type, args):
            try c.encode("call_service", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(service, forKey: .service)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encodeIfPresent(args, forKey: .args)
        }
    }

    func encodedText() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Server → client routing envelope. Payload fields (`msg`, `values`) are deliberately NOT
/// decoded here: JSONDecoder skips unknown keys, so this stays one cheap pass; subscribers
/// then decode `PublishEnvelope<T>` straight from the same bytes (one parse per subscriber).
struct IncomingFrame: Decodable, Sendable {
    enum Op: String, Decodable, Sendable {
        case publish
        case serviceResponse = "service_response"
        case status
        case callService = "call_service"
    }

    let op: String
    let id: String?
    let topic: String?
    let service: String?
    let result: Bool?
    let level: String?

    var knownOp: Op? { Op(rawValue: op) }

    static func decode(_ data: Data) throws -> IncomingFrame {
        do {
            return try JSONDecoder().decode(IncomingFrame.self, from: data)
        } catch {
            throw RosbridgeError.decoding("frame: \(error)")
        }
    }

    static func decode(_ text: String) throws -> IncomingFrame {
        try decode(Data(text.utf8))
    }
}

/// `publish` frame with the message decoded as `T` (snake_case keys via `ROSJSON`).
struct PublishEnvelope<T: Decodable>: Decodable {
    let msg: T
}

/// `service_response`: object on success, error string on failure.
struct ServiceValuesFrame: Decodable {
    let values: JSONValue?
}

/// `status`: human-readable message.
struct StatusFrame: Decodable {
    let msg: String?
}

/// `/rosapi/topics` response.
public struct TopicInfo: Sendable, Equatable, Hashable, Identifiable {
    public let name: String
    public let type: String
    public var id: String {
        name
    }

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

struct TopicsResponse: Decodable {
    let topics: [String]
    let types: [String]

    var infos: [TopicInfo] {
        zip(topics, types).map { TopicInfo(name: $0, type: $1) }
    }
}
