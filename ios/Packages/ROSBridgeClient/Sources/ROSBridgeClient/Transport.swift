import Foundation
import os

/// Minimal text websocket abstraction so the client can be driven by a mock in tests.
public protocol WebSocketTransport: Sendable {
    /// Opens the socket; returns once the handshake completed, throws on failure.
    func connect() async throws
    func send(_ text: String) async throws
    /// Waits for the next text frame. Throws when the connection is gone.
    func receive() async throws -> String
    func close() async
}

/// Production transport over `URLSessionWebSocketTask`.
public actor URLSessionWebSocketTransport: WebSocketTransport {
    private let url: URL
    private let session: URLSession
    private let delegate: OpenDelegate
    private var task: URLSessionWebSocketTask?

    public init(url: URL, connectTimeout: TimeInterval = 10) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.waitsForConnectivity = false
        delegate = OpenDelegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func connect() async throws {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024 // robot_description + large TF trees
        self.task = task
        try await delegate.waitForOpen { task.resume() }
    }

    public func send(_ text: String) async throws {
        guard let task else { throw RosbridgeError.notConnected }
        do {
            try await task.send(.string(text))
        } catch {
            throw RosbridgeError.transport(error.localizedDescription)
        }
    }

    public func receive() async throws -> String {
        guard let task else { throw RosbridgeError.notConnected }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw RosbridgeError.connectionClosed
        }
        switch message {
        case let .string(s): return s
        case let .data(d): return String(decoding: d, as: UTF8.self)
        @unknown default: throw RosbridgeError.decoding("unknown websocket message kind")
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// Bridges the delegate's open/close callbacks to a single continuation.
    private final class OpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)

        func waitForOpen(_ start: @Sendable () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.withLock { $0 = cont }
                start()
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            let cont = lock.withLock { c -> CheckedContinuation<Void, Error>? in
                defer { c = nil }
                return c
            }
            cont?.resume(with: result)
        }

        func urlSession(
            _: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?
        ) {
            finish(.success(()))
        }

        func urlSession(
            _: URLSession, webSocketTask _: URLSessionWebSocketTask,
            didCloseWith code: URLSessionWebSocketTask.CloseCode, reason _: Data?
        ) {
            finish(.failure(RosbridgeError.transport("closed during handshake (\(code.rawValue))")))
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(RosbridgeError.transport(error.localizedDescription)))
            }
        }
    }
}
