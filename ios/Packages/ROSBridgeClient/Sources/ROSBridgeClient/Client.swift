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
        let scaled = (initialDelay / .seconds(1)) * pow(multiplier, Double(max(0, attempt - 1)))
        return .seconds(min(scaled, maxDelay / .seconds(1)))
    }
}

/// Liveness probing. A half-open TCP connection (peer's Wi-Fi dropped, cable pulled) delivers no
/// error for minutes; a missed websocket pong turns it into a `connectionLost` quickly.
public struct HeartbeatPolicy: Sendable {
    public var enabled: Bool
    public var interval: Duration
    public var timeout: Duration

    public init(enabled: Bool = true, interval: Duration = .seconds(2), timeout: Duration = .seconds(3)) {
        self.enabled = enabled
        self.interval = interval
        self.timeout = timeout
    }

    public static let `default` = HeartbeatPolicy()
    public static let none = HeartbeatPolicy(enabled: false)
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
/// re-subscription, heartbeat. All state lives in the actor; consumers get `AsyncStream`s.
///
/// Lifecycle invariants:
/// - `generation` increments on every `connect()`/`disconnect()`. Any transport opened for an
///   older generation is closed and discarded when its handshake finally returns.
/// - Loops (receive, heartbeat) are bound to their transport and only report loss while that
///   transport is still the current one (`transport === t`).
public actor RosbridgeClient {
    public typealias TransportFactory = @Sendable (URL) -> any WebSocketTransport

    private let makeTransport: TransportFactory
    private let policy: ReconnectPolicy
    private let heartbeat: HeartbeatPolicy
    private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ROSBridgeClient")

    private var url: URL?
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var userDisconnected = true
    private var generation = 0
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
        /// Receives the raw frame bytes; decodes `msg` as its own `T` (one parse per subscriber).
        let sink: @Sendable (Data) -> Void
        let finish: @Sendable () -> Void
    }

    private var subscriptions: [String: SubscriptionEntry] = [:]
    private var advertisements: [String: (id: String, type: String)] = [:] // by topic
    private var pendingServices: [String: CheckedContinuation<JSONValue, Error>] = [:]

    public init(
        transportFactory: @escaping TransportFactory = { URLSessionWebSocketTransport(url: $0) },
        reconnect: ReconnectPolicy = .default,
        heartbeat: HeartbeatPolicy = .default
    ) {
        makeTransport = transportFactory
        policy = reconnect
        self.heartbeat = heartbeat
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
            try await openAndRegister(url)
        } catch {
            if !userDisconnected {
                state = .failed(describe(error))
            }
            throw error
        }
        state = .connected
        log.info("connected to \(url.absoluteString, privacy: .public)")
    }

    public func disconnect() async {
        userDisconnected = true
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardownTransport()
        failAllPending(RosbridgeError.connectionClosed)
        state = .disconnected
    }

    /// Opens a transport for the current generation and re-sends registrations. On any failure
    /// the transport (if opened) is torn down so nothing is left running.
    private func openAndRegister(_ url: URL) async throws {
        try await openTransport(url)
        do {
            try await resendRegistrations()
        } catch {
            await teardownTransport()
            throw error
        }
    }

    private func openTransport(_ url: URL) async throws {
        let myGeneration = generation
        let t = makeTransport(url)
        try await t.connect()
        // While we were handshaking the user may have called connect()/disconnect().
        guard myGeneration == generation, !userDisconnected else {
            await t.close()
            throw RosbridgeError.connectionClosed
        }
        await teardownTransport() // never stack transports
        transport = t
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(t)
        }
        if heartbeat.enabled {
            heartbeatTask = Task { [weak self] in
                await self?.heartbeatLoop(t)
            }
        }
    }

    private func teardownTransport() async {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let t = transport {
            transport = nil
            await t.close()
        }
    }

    private func receiveLoop(_ t: any WebSocketTransport) async {
        while !Task.isCancelled {
            do {
                let text = try await t.receive()
                guard transport === t else { return }
                handle(text)
            } catch {
                if !Task.isCancelled {
                    await connectionLost(t, error)
                }
                return
            }
        }
    }

    /// Pings on a fixed cadence; a pong that does not arrive within `heartbeat.timeout` is treated
    /// exactly like a socket error. Each transport gets its own loop, so stale loops die with it.
    private func heartbeatLoop(_ t: any WebSocketTransport) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: heartbeat.interval)
            } catch {
                return
            }
            guard !Task.isCancelled, transport === t else { return }
            let alive = await Self.ping(t, timeout: heartbeat.timeout)
            if !alive, !Task.isCancelled {
                await connectionLost(t, RosbridgeError.timeout("heartbeat"))
                return
            }
        }
    }

    private static func ping(_ t: any WebSocketTransport, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await (try? t.ping()) != nil }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Only the *current* transport may report a loss; stale loops from replaced sockets are ignored.
    private func connectionLost(_ t: any WebSocketTransport, _ error: Error) async {
        guard transport === t, !userDisconnected else { return }
        log.error("connection lost: \(self.describe(error), privacy: .public)")
        await teardownTransport()
        failAllPending(RosbridgeError.connectionClosed)
        guard policy.enabled, let url else {
            state = .failed(describe(error))
            return
        }
        state = .reconnecting(attempt: 1)
        let gen = generation
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(url, generation: gen)
        }
    }

    private func reconnectLoop(_ url: URL, generation gen: Int) async {
        var attempt = 1
        while !Task.isCancelled, !userDisconnected, gen == generation {
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
            guard gen == generation, !userDisconnected else { return }
            do {
                try await openAndRegister(url)
                guard gen == generation else { return } // superseded while handshaking
                state = .connected
                log.info("reconnected after \(attempt) attempt(s)")
                return
            } catch {
                if gen != generation || userDisconnected {
                    return
                }
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
            sink: { data in
                do {
                    try cont.yield(ROSJSON.decode(PublishEnvelope<T>.self, from: data).msg)
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
        let data = Data(text.utf8)
        let frame: IncomingFrame
        do {
            frame = try IncomingFrame.decode(data)
        } catch {
            log.error("bad frame: \(String(describing: error), privacy: .public)")
            return
        }
        switch frame.knownOp {
        case .publish:
            guard let topic = frame.topic else { return }
            for entry in subscriptions.values where entry.topic == topic {
                entry.sink(data)
            }
        case .serviceResponse:
            guard let id = frame.id, let cont = pendingServices.removeValue(forKey: id) else { return }
            let values = (try? JSONDecoder().decode(ServiceValuesFrame.self, from: data))?.values
            if frame.result == false {
                let message = values?.stringValue ?? "unknown error"
                cont.resume(throwing: RosbridgeError.serviceFailed(
                    service: frame.service ?? "?", message: message
                ))
            } else {
                cont.resume(returning: values ?? .null)
            }
        case .status:
            let level = frame.level ?? "info"
            let message = (try? JSONDecoder().decode(StatusFrame.self, from: data))?.msg ?? text
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
