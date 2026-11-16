import Foundation
import os

/// Minimal text websocket abstraction so the client can be driven by a mock in tests.
/// Transports are one-shot reference types: `connect` once, `close` once; identity (`===`) lets
/// the client ignore callbacks from a transport it has already replaced.
public protocol WebSocketTransport: AnyObject, Sendable {
    /// Opens the socket; returns once the handshake completed, throws on failure.
    func connect() async throws
    func send(_ text: String) async throws
    /// Waits for the next text frame. Throws when the connection is gone.
    func receive() async throws -> String
    /// Websocket ping; returns when the pong arrives, throws if the socket is dead or the task is cancelled.
    func ping() async throws
    /// Tears the connection down and releases all resources. Idempotent.
    func close() async
}

/// A continuation that may be resumed exactly once from any thread (pong handler, delegate
/// callback, or task cancellation). Later calls are no-ops.
final class ResumeOnce: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)

    func store(_ c: CheckedContinuation<Void, Error>) {
        lock.withLock { $0 = c }
    }

    func resume(_ r: Result<Void, Error>) {
        let c = lock.withLock { s -> CheckedContinuation<Void, Error>? in
            defer { s = nil }
            return s
        }
        c?.resume(with: r)
    }
}

/// Production transport over `URLSessionWebSocketTask`.
public actor URLSessionWebSocketTransport: WebSocketTransport {
    private let url: URL
    private let session: URLSession
    private let delegate: OpenDelegate
    private var task: URLSessionWebSocketTask?
    private var closed = false

    public init(url: URL, connectTimeout: TimeInterval = 10) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.waitsForConnectivity = false
        delegate = OpenDelegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func connect() async throws {
        guard !closed else { throw RosbridgeError.connectionClosed }
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

    /// Cancellation-aware: `sendPing`'s handler never fires on a half-open socket, so the caller's
    /// timeout cancels us and we must resume then — otherwise a structured `withTaskGroup` around
    /// this call would wait forever.
    public func ping() async throws {
        guard let task else { throw RosbridgeError.notConnected }
        let box = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.store(cont)
                // The cancel handler may have run before `store`; honour it now.
                if Task.isCancelled {
                    box.resume(.failure(RosbridgeError.timeout("ping")))
                    return
                }
                task.sendPing { error in
                    if let error {
                        box.resume(.failure(RosbridgeError.transport(error.localizedDescription)))
                    } else {
                        box.resume(.success(()))
                    }
                }
            }
        } onCancel: {
            box.resume(.failure(RosbridgeError.timeout("ping")))
        }
    }

    /// Cancels the socket and invalidates the session (which otherwise retains its delegate forever).
    public func close() async {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session.invalidateAndCancel()
        delegate.fail(RosbridgeError.connectionClosed)
    }

    /// Bridges the delegate's open/close callbacks to a single continuation.
    private final class OpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let once = ResumeOnce()

        func waitForOpen(_ start: @Sendable () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                once.store(cont)
                start()
            }
        }

        func fail(_ error: Error) {
            once.resume(.failure(error))
        }

        func urlSession(
            _: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?
        ) {
            once.resume(.success(()))
        }

        func urlSession(
            _: URLSession, webSocketTask _: URLSessionWebSocketTask,
            didCloseWith code: URLSessionWebSocketTask.CloseCode, reason _: Data?
        ) {
            once.resume(.failure(RosbridgeError.transport("closed during handshake (\(code.rawValue))")))
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                once.resume(.failure(RosbridgeError.transport(error.localizedDescription)))
            }
        }
    }
}
