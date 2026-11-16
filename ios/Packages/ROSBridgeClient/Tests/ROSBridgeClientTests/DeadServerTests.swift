import Foundation
@testable import ROSBridgeClient
import Testing

/// Against `tools/fake_dead_bridge.py`: the server accepts and then never pongs or answers.
/// Run with `MRROS_IT_DEADBRIDGE=ws://127.0.0.1:9099` (see tools/it-deadbridge.sh).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MRROS_IT_DEADBRIDGE"] != nil), .serialized)
struct DeadServerTests {
    private var url: URL {
        URL(string: ProcessInfo.processInfo.environment["MRROS_IT_DEADBRIDGE"]!)!
    }

    /// A bounded race: first child to finish wins; the loser must honour cancellation.
    private func race<T: Sendable>(
        timeout: Duration, _ body: @escaping @Sendable () async -> T, onTimeout: T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return onTimeout
            }
            let first = await group.next() ?? onTimeout
            group.cancelAll()
            return first
        }
    }

    @Test func rawPingIsCancellableOnDeadPeer() async throws {
        let t = URLSessionWebSocketTransport(url: url)
        try await t.connect()
        let start = ContinuousClock.now
        let result = await race(timeout: .seconds(2), {
            do {
                try await t.ping()
                return "pong"
            } catch {
                return "error"
            }
        }, onTimeout: "timeout")
        let elapsed = ContinuousClock.now - start
        print("DEADBRIDGE raw ping → \(result) after \(elapsed)")
        #expect(result == "timeout")
        #expect(elapsed < .seconds(4), "task group must not hang on the cancelled ping")
        await t.close()
    }

    @Test func clientDetectsDeadPeerViaHeartbeat() async throws {
        let client = RosbridgeClient(
            reconnect: ReconnectPolicy(initialDelay: .seconds(1), maxDelay: .seconds(1), maxAttempts: 1),
            heartbeat: HeartbeatPolicy(interval: .milliseconds(300), timeout: .milliseconds(700))
        )
        try await client.connect(to: url)
        let states = await client.states()
        let start = ContinuousClock.now
        let detected = await race(timeout: .seconds(6), {
            for await s in states {
                if case .reconnecting = s {
                    return true
                }
                if case .failed = s {
                    return true
                }
            }
            return false
        }, onTimeout: false)
        print("DEADBRIDGE heartbeat detected=\(detected) after \(ContinuousClock.now - start)")
        #expect(detected)
        await client.disconnect()
    }
}
