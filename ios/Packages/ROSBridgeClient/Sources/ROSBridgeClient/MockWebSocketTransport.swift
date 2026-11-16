import Foundation
import ROSMessages

/// Scripted transport for tests and previews: push inbound frames, inspect outbound ones.
/// Starts closed; `connect()` opens it unless `failConnect` is set.
public actor MockWebSocketTransport: WebSocketTransport {
    public struct Closed: Error {}

    public private(set) var sent: [String] = []
    public private(set) var connectAttempts = 0
    public var failConnect = false
    public var failPing = false
    public private(set) var closeCount = 0
    private var connectDelay: Duration?

    private var queue: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = true

    public init() {}

    public func connect() async throws {
        connectAttempts += 1
        if let connectDelay {
            try await Task.sleep(for: connectDelay)
        }
        if failConnect {
            throw RosbridgeError.transport("mock refused")
        }
        closed = false
    }

    public func send(_ text: String) async throws {
        if closed {
            throw RosbridgeError.notConnected
        }
        sent.append(text)
    }

    public func receive() async throws -> String {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        if closed {
            throw Closed()
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    public func ping() async throws {
        if closed || failPing { throw Closed() }
    }

    public func close() async {
        closeCount += 1
        dropConnection()
    }

    // MARK: Test controls

    /// Deliver a frame to the client (queued if it is not waiting yet).
    public func push(_ text: String) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: text)
        } else {
            queue.append(text)
        }
    }

    /// Simulate the server going away.
    public func dropConnection() {
        closed = true
        let w = waiters
        waiters.removeAll()
        for c in w {
            c.resume(throwing: Closed())
        }
    }

    /// Make `connect()` take this long (simulates a slow or hanging handshake).
    public func setConnectDelay(_ d: Duration?) {
        connectDelay = d
    }

    public func setFailConnect(_ v: Bool) {
        failConnect = v
    }

    /// Simulate a half-open socket: receive() keeps waiting but pongs never come back.
    public func setFailPing(_ v: Bool) {
        failPing = v
    }

    /// Outbound frames parsed as JSON.
    public func sentOps() -> [JSONValue] {
        sent.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// Wait until `count` frames were sent (bounded).
    public func waitForSent(count: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while sent.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sent.count >= count
    }
}
