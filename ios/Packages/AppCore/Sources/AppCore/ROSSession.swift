import Foundation
import Observation
import os
import ROSBridgeClient
import ROSMessages
import URDFKit

/// Main-actor façade over `RosbridgeClient` for the UI: connection lifecycle, the live
/// `/joint_states`, the robot description, and the topic list.
@MainActor
@Observable
public final class ROSSession {
    public var settings: ConnectionSettings {
        didSet {
            if settings != oldValue {
                settings.save(to: defaults)
            }
        }
    }

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var lastError: String?
    public private(set) var topics: [TopicInfo] = []
    public private(set) var jointState: SensorMsgs.JointState?
    /// Flips once when `/joint_states` starts (and back on disconnect). Views that only need to
    /// know joints exist observe this, not `jointState` — which changes ~30×/s and would
    /// re-render them on every message.
    public private(set) var isReceivingJoints = false
    /// Measured `/joint_states` rate over the last ~1 s window.
    public private(set) var jointRateHz: Double = 0
    /// Wall-clock time of the last `/joint_states`; the UI flags the panel stale when this ages.
    public private(set) var lastJointUpdate: Date?
    public private(set) var robotName: String?
    public private(set) var urdf: String?
    /// Parsed robot description (nil until a valid URDF arrived; see `urdfError`).
    public private(set) var urdfRobot: URDFRobot?
    public private(set) var urdfError: String?

    public var isConnected: Bool {
        state.isConnected
    }

    private let client: RosbridgeClient
    private let defaults: UserDefaults
    private var tasks: [Task<Void, Never>] = []
    private var jointStamps: [ContinuousClock.Instant] = []
    private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "AppCore")

    public init(
        transportFactory: RosbridgeClient.TransportFactory? = nil,
        reconnect: ReconnectPolicy = .default,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        settings = ConnectionSettings.load(from: defaults)
        if let transportFactory {
            client = RosbridgeClient(transportFactory: transportFactory, reconnect: reconnect)
        } else {
            client = RosbridgeClient(reconnect: reconnect)
        }
    }

    // MARK: - Lifecycle

    public func connect() async {
        guard let url = settings.url else {
            lastError = "Invalid host or port"
            return
        }
        lastError = nil
        stopTasks()
        tasks.append(Task { [weak self, client] in
            for await s in await client.states() {
                guard let self else { return }
                state = s
                if case let .failed(reason) = s {
                    lastError = reason
                }
            }
        })
        do {
            try await client.connect(to: url)
        } catch {
            lastError = (error as? RosbridgeError).map { "\($0)" } ?? error.localizedDescription
            log.error("connect failed: \(self.lastError ?? "?", privacy: .public)")
            return
        }
        startSubscriptions()
        await refreshTopics()
    }

    public func disconnect() async {
        stopTasks()
        await client.disconnect()
        state = .disconnected
        jointState = nil
        isReceivingJoints = false
        jointRateHz = 0
        lastJointUpdate = nil
        robotName = nil
        urdf = nil
        urdfRobot = nil
        urdfError = nil
        topics = []
        jointStamps.removeAll()
    }

    public func refreshTopics() async {
        do {
            topics = try await client.topics().sorted { $0.name < $1.name }
        } catch {
            lastError = "topics: \(error)"
        }
    }

    // MARK: - Subscriptions

    private func startSubscriptions() {
        tasks.append(Task { [weak self, client] in
            let sub = await client.subscribe(
                "/joint_states",
                as: SensorMsgs.JointState.self,
                throttleMilliseconds: 33
            )
            defer { sub.cancel() }
            for await js in sub.messages {
                guard let self else { return }
                jointState = js
                if !isReceivingJoints { isReceivingJoints = true }
                lastJointUpdate = Date()
                noteJointStamp()
            }
        })
        tasks.append(Task { [weak self, client] in
            let sub = await client.subscribe("/robot_description", as: StdMsgs.StringMessage.self)
            defer { sub.cancel() }
            for await msg in sub.messages {
                guard let self else { return }
                // Parse off the main actor: a full robot description is a long XML document, and
                // parsing it here froze the AR view for a moment right after connecting.
                let text = msg.data
                let start = ContinuousClock.now
                let (result, fallbackName) = await Task.detached(priority: .userInitiated) {
                    (Result { try URDFParser.parse(text) }, Self.robotName(in: text))
                }.value
                let elapsed = ContinuousClock.now - start
                log.info(
                    "URDF \(text.utf8.count, privacy: .public) B parsed off-main in \(elapsed, privacy: .public)"
                )
                urdf = text
                switch result {
                case let .success(parsed):
                    urdfRobot = parsed
                    urdfError = nil
                    robotName = parsed.name.isEmpty ? fallbackName : parsed.name
                case let .failure(error):
                    urdfRobot = nil
                    urdfError = "\(error)"
                    robotName = fallbackName
                    log.error("URDF parse failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
    }

    private func stopTasks() {
        for t in tasks {
            t.cancel()
        }
        tasks.removeAll()
    }

    private func noteJointStamp() {
        let now = ContinuousClock.now
        jointStamps.append(now)
        jointStamps.removeAll { now - $0 > .seconds(1) }
        if jointStamps.count >= 2, let first = jointStamps.first {
            let seconds = (now - first) / .seconds(1)
            jointRateHz = seconds > 0 ? Double(jointStamps.count - 1) / seconds : 0
        }
    }

    /// `<robot … name="…">` from a URDF string, without a full XML parse (URDFKit does that in M2).
    /// Matches the attribute `name` only (not `filename=`), anywhere inside the `<robot` tag.
    nonisolated static func robotName(in urdf: String) -> String? {
        let pattern = /<robot\b[^>]*?\sname="([^"]+)"/
        return urdf.firstMatch(of: pattern).map { String($0.1) }
    }
}
