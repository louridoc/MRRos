import Foundation
import ROSMessages
@testable import ROSBridgeClient

/// Scripted transport: tests push inbound frames and inspect outbound ones.
actor MockTransport: WebSocketTransport {
    struct Closed: Error {}

    private(set) var sent: [String] = []
    private(set) var connectAttempts = 0
    var failConnect = false

    private var queue: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = true

    func connect() async throws {
        connectAttempts += 1
        if failConnect {
            throw RosbridgeError.transport("mock refused")
        }
        closed = false
    }

    func send(_ text: String) async throws {
        if closed {
            throw RosbridgeError.notConnected
        }
        sent.append(text)
    }

    func receive() async throws -> String {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        if closed {
            throw Closed()
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() async {
        dropConnection()
    }

    // MARK: test controls

    func push(_ text: String) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: text)
        } else {
            queue.append(text)
        }
    }

    func dropConnection() {
        closed = true
        let w = waiters
        waiters.removeAll()
        for c in w {
            c.resume(throwing: Closed())
        }
    }

    func setFailConnect(_ v: Bool) {
        failConnect = v
    }

    func sentOps() -> [JSONValue] {
        sent.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// Wait until `count` frames were sent (bounded).
    func waitForSent(count: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while sent.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sent.count >= count
    }
}

enum Fixtures {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            throw NSError(
                domain: "Fixtures",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing \(name)"]
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Fixture with its `id` rewritten so it matches a client-generated request id.
    static func text(_ name: String, id: String) throws -> String {
        var obj = try JSONSerialization.jsonObject(with: Data(text(name).utf8)) as? [String: Any] ?? [:]
        obj["id"] = id
        return try String(decoding: JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
}
