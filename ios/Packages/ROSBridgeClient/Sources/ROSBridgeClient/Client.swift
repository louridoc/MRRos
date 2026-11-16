import Foundation
import os
import ROSMessages

// NOTE: this file is named Client.swift on purpose — `RosbridgeClient.swift` collides with
// `ROSBridgeClient.swift` on case-insensitive macOS filesystems.

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool {
        self == .connected
    }
}

public struct ReconnectPolicy: Sendable {
    public var enabled: Bool
    public var initialDelay: Duration
    public var maxDelay: Duration
    public var multiplier: Double
    /// `nil` = retry forever.
    public var maxAttempts: Int?

    public init(
        enabled: Bool = true,
        initialDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(10),
        multiplier: Double = 2,
        maxAttempts: Int? = nil
    ) {
        self.enabled = enabled
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.maxAttempts = maxAttempts
    }

    public static let `default` = ReconnectPolicy()
    public static let none = ReconnectPolicy(enabled: false)

    func delay(forAttempt attempt: Int) -> Duration {
        func secs(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let scaled = secs(initialDelay) * pow(multiplier, Double(max(0, attempt - 1)))
        return .seconds(min(scaled, secs(maxDelay)))
    }
}

/// A live topic subscription. Messages arrive on `messages`; `cancel()` (or dropping the stream)
/// unsubscribes on the bridge.
public struct Subscription<T: ROSMessage>: Sendable {
    public let id: String
    public let topic: String
    public let messages: AsyncStream<T>
    let onCancel: @Sendable () -> Void

    public func cancel() {
        onCancel()
    }
}

/// rosbridge v2 client: subscriptions, publishing, service calls, automatic reconnect with
/// re-subscription. All state lives in the actor; consumers get `AsyncStream`s.
public actor RosbridgeClient {
    public typealias TransportFactory = @Sendable (URL) -> any WebSocketTransport

    private let makeTransport: TransportFactory
    private let policy: ReconnectPolicy
    private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ROSBridgeClient")

    private var url: URL?
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var userDisconnected = true
    private var nextId = 0

    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            for cont in stateContinuations.values {
                cont.yield(state)
            }
        }
    }

    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    private struct SubscriptionEntry {
        let topic: String
        let type: String
        let throttleRate: Int
        let queueLength: Int
        let sink: @Sendable (JSONValue) -> Void
        let finish: @Sendable () -> Void
    }

    private var subscriptions: [String: SubscriptionEntry] = [:]
    private var advertisements: [String: (id: String, type: String)] = [:] // by topic
    private var pendingServices: [String: CheckedContinuation<JSONValue, Error>] = [:]

    public init(
        transportFactory: @escaping TransportFactory = { URLSessionWebSocketTransport(url: $0) },
        reconnect: ReconnectPolicy = .default
    ) {
        makeTransport = transportFactory
        policy = reconnect
    }

    // MARK: - Connection

    /// Observe state changes. Each call gets its own stream, primed with the current state.
    public func states() -> AsyncStream<ConnectionState> {
        let key = UUID()
        let (stream, cont) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stateContinuations[key] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(key) }
        }
        return stream
    }

    private func removeStateObserver(_ key: UUID) {
        stateContinuations[key] = nil
    }

    /// Connects and returns once the websocket is open and existing subscriptions are re-sent.
    /// Throws on first-attempt failure; later drops are handled by the reconnect policy.
    public func connect(to url: URL) async throws {
        await disconnect()
        self.url = url
        userDisconnected = false
        state = .connecting
        do {
            try await openTransport(url)
        } catch {
            state = .failed(describe(error))
            throw error
        }
        try await resendRegistrations()
        state = .connected
        log.info("connected to \(url.absoluteString, privacy: .public)")
    }

    public func disconnect() async {
        userDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        if let t = transport {
            await t.close()
        }
        transport = nil
        failAllPending(RosbridgeError.connectionClosed)
        state = .disconnected
    }

    private func openTransport(_ url: URL) async throws {
        let t = makeTransport(url)
        try await t.connect()
        transport = t
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(t)
        }
    }

    private func receiveLoop(_ t: any WebSocketTransport) async {
        while !Task.isCancelled {
            do {
                let text = try await t.receive()
                handle(text)
            } catch {
                if !userDisconnected {
                    connectionLost(error)
                }
                return
            }
        }
    }

    private func connectionLost(_ error: Error) {
        log.error("connection lost: \(self.describe(error), privacy: .public)")
        transport = nil
        receiveTask = nil
        failAllPending(RosbridgeError.connectionClosed)
        guard policy.enabled, let url else {
            state = .failed(describe(error))
            return
        }
        state = .reconnecting(attempt: 1)
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(url)
        }
    }

    private func reconnectLoop(_ url: URL) async {
        var attempt = 1
        while !Task.isCancelled, !userDisconnected {
            if let max = policy.maxAttempts, attempt > max {
                state = .failed("gave up after \(max) attempts")
                return
            }
            state = .reconnecting(attempt: attempt)
            do {
                try await Task.sleep(for: policy.delay(forAttempt: attempt))
            } catch {
                return // cancelled
            }
            do {
                try await openTransport(url)
                try await resendRegistrations()
                state = .connected
                log.info("reconnected after \(attempt) attempt(s)")
                return
            } catch {
                log.warning("reconnect attempt \(attempt) failed: \(self.describe(error), privacy: .public)")
                attempt += 1
            }
        }
    }

    private func resendRegistrations() async throws {
        for (topic, ad) in advertisements {
            try await send(.advertise(id: ad.id, topic: topic, type: ad.type))
        }
        for (id, s) in subscriptions {
            try await send(.subscribe(
                id: id, topic: s.topic, type: s.type,
                throttleRate: s.throttleRate, queueLength: s.queueLength
            ))
        }
    }

    // MARK: - Topics

    /// Subscribe to `topic` as `T`. Works before `connect`; the subscribe op is (re)sent on every
    /// (re)connect. Undecodable messages are logged and dropped.
    public func subscribe<T: ROSMessage>(
        _ topic: String,
        as _: T.Type,
        throttleMilliseconds: Int = 0,
        queueLength: Int = 1
    ) -> Subscription<T> {
        let id = makeId("sub")
        let (stream, cont) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(queueLength))
        let log = log
        let entry = SubscriptionEntry(
            topic: topic, type: T.rosType, throttleRate: throttleMilliseconds, queueLength: queueLength,
            sink: { value in
                do {
                    try cont.yield(value.decode(as: T.self))
                } catch {
                    log
                        .error(
                            "drop \(topic, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                }
            },
            finish: { cont.finish() }
        )
        subscriptions[id] = entry
        cont.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        if state.isConnected {
            Task { [weak self] in
                try? await self?.send(.subscribe(
                    id: id, topic: topic, type: T.rosType,
                    throttleRate: throttleMilliseconds, queueLength: queueLength
                ))
            }
        }
        return Subscription(id: id, topic: topic, messages: stream, onCancel: { [weak self] in
            Task { await self?.unsubscribe(id: id) }
        })
    }

    private func unsubscribe(id: String) async {
        guard let entry = subscriptions.removeValue(forKey: id) else { return }
        entry.finish()
        if state.isConnected {
            try? await send(.unsubscribe(id: id, topic: entry.topic))
        }
    }

    public func advertise<T: ROSMessage>(_ topic: String, as _: T.Type) async throws {
        let id = makeId("adv")
        advertisements[topic] = (id, T.rosType)
        if state.isConnected {
            try await send(.advertise(id: id, topic: topic, type: T.rosType))
        }
    }

    public func publish<T: ROSMessage>(_ message: T, to topic: String) async throws {
        guard state.isConnected else { throw RosbridgeError.notConnected }
        if advertisements[topic] == nil {
            try await advertise(topic, as: T.self)
        }
        try await send(.publish(topic: topic, msg: JSONValue.from(message)))
    }

    // MARK: - Services

    public func callService<Res: Decodable>(
        _ service: String,
        type: String? = nil,
        args: JSONValue? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> Res {
        let raw = try await callServiceRaw(service, type: type, args: args, timeout: timeout)
        do {
            return try raw.decode(as: Res.self)
        } catch {
            throw RosbridgeError.decoding("\(service) response: \(error)")
        }
    }

    public func callServiceRaw(
        _ service: String,
        type: String? = nil,
        args: JSONValue? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> JSONValue {
        guard state.isConnected, let transport else { throw RosbridgeError.notConnected }
        let id = makeId("svc")
        let text = try OutgoingOp.callService(id: id, service: service, type: type, args: args).encodedText()
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.failPending(id, RosbridgeError.timeout(service))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pendingServices[id] = cont
            Task { [weak self] in
                do {
                    try await transport.send(text)
                } catch {
                    await self?.failPending(id, RosbridgeError.transport(String(describing: error)))
                }
            }
        }
    }

    /// Topics currently known to the bridge (`/rosapi/topics`).
    public func topics() async throws -> [TopicInfo] {
        let r: TopicsResponse = try await callService("/rosapi/topics")
        return r.infos
    }

    // MARK: - Internals

    private func send(_ op: OutgoingOp) async throws {
        guard let transport else { throw RosbridgeError.notConnected }
        try await transport.send(op.encodedText())
    }

    private func handle(_ text: String) {
        let frame: IncomingFrame
        do {
            frame = try IncomingFrame.decode(text)
        } catch {
            log.error("bad frame: \(String(describing: error), privacy: .public)")
            return
        }
        switch frame.knownOp {
        case .publish:
            guard let topic = frame.topic, let msg = frame.msg else { return }
            for entry in subscriptions.values where entry.topic == topic {
                entry.sink(msg)
            }
        case .serviceResponse:
            guard let id = frame.id, let cont = pendingServices.removeValue(forKey: id) else { return }
            if frame.result == false {
                let message = frame.values?.stringValue ?? "unknown error"
                cont.resume(throwing: RosbridgeError.serviceFailed(
                    service: frame.service ?? "?", message: message
                ))
            } else {
                cont.resume(returning: frame.values ?? .null)
            }
        case .status:
            let level = frame.level ?? "info"
            let message = frame.msg?.stringValue ?? text
            log.log(
                level: level == "error" ? .error : .info,
                "rosbridge status: \(message, privacy: .public)"
            )
        case .callService, .none:
            log.debug("ignored op \(frame.op, privacy: .public)")
        }
    }

    private func failPending(_ id: String, _ error: RosbridgeError) {
        pendingServices.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(_ error: RosbridgeError) {
        let pending = pendingServices
        pendingServices.removeAll()
        for cont in pending.values {
            cont.resume(throwing: error)
        }
    }

    private func makeId(_ prefix: String) -> String {
        nextId += 1
        return "\(prefix)_\(nextId)"
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? RosbridgeError {
            return "\(e)"
        }
        return error.localizedDescription
    }
}
