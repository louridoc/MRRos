import Foundation
@testable import ROSBridgeClient
import ROSMessages
import Testing

private let testURL = URL(string: "ws://mock:9090")!
private let fastReconnect = ReconnectPolicy(
    initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), multiplier: 2, maxAttempts: 5
)

struct ClientTests {
    private func makeClient(policy: ReconnectPolicy = fastReconnect) -> (RosbridgeClient, MockWebSocketTransport) {
        let mock = MockWebSocketTransport()
        let client = RosbridgeClient(transportFactory: { _ in mock }, reconnect: policy)
        return (client, mock)
    }

    @Test func connectTransitionsState() async throws {
        let (client, mock) = makeClient()
        let states = await client.states()
        try await client.connect(to: testURL)
        #expect(await client.state == .connected)
        #expect(await mock.connectAttempts == 1)
        await client.disconnect()
        #expect(await client.state == .disconnected)

        var seen: [ConnectionState] = []
        for await s in states {
            seen.append(s)
            if s == .disconnected, seen.count > 1 {
                break
            }
        }
        #expect(seen == [.disconnected, .connecting, .connected, .disconnected])
    }

    @Test func connectFailureThrowsAndSetsFailed() async {
        let (client, mock) = makeClient(policy: .none)
        await mock.setFailConnect(true)
        await #expect(throws: RosbridgeError.self) {
            try await client.connect(to: testURL)
        }
        guard case .failed = await client.state else {
            await Issue.record("expected .failed, got \(client.state)")
            return
        }
    }

    @Test func subscribeSendsOpAndDeliversDecodedMessages() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        let sub = await client.subscribe(
            "/joint_states",
            as: SensorMsgs.JointState.self,
            throttleMilliseconds: 33
        )
        #expect(await mock.waitForSent(count: 1))
        let op = await mock.sentOps().last
        #expect(op?["op"]?.stringValue == "subscribe")
        #expect(op?["topic"]?.stringValue == "/joint_states")
        #expect(op?["type"]?.stringValue == "sensor_msgs/msg/JointState")
        #expect(op?["throttle_rate"]?.doubleValue == 33)

        try await mock.push(Fixtures.text("publish_joint_states"))
        var it = sub.messages.makeAsyncIterator()
        let js = await it.next()
        #expect(js?.name.count == 6)
        #expect(js?.positionsByName["J1"] != nil)

        sub.cancel()
        #expect(await mock.waitForSent(count: 2))
        #expect(await mock.sentOps().last?["op"]?.stringValue == "unsubscribe")
        await client.disconnect()
    }

    @Test func undecodableMessageIsDroppedNotFatal() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        let sub = await client.subscribe("/joint_states", as: SensorMsgs.JointState.self)
        await mock.push(#"{"op":"publish","topic":"/joint_states","msg":{"name":"not-an-array"}}"#)
        try await mock.push(Fixtures.text("publish_joint_states"))
        var it = sub.messages.makeAsyncIterator()
        let js = await it.next()
        #expect(js?.name.first == "J1")
        await client.disconnect()
    }

    @Test func serviceCallRoundTrip() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        async let topics = client.topics()
        #expect(await mock.waitForSent(count: 1))
        let id = try #require(await mock.sentOps().last?["id"]?.stringValue)
        try await mock.push(Fixtures.text("service_response_topics", id: id))
        let result = try await topics
        #expect(result.contains(TopicInfo(name: "/tf", type: "tf2_msgs/msg/TFMessage")))
        await client.disconnect()
    }

    @Test func serviceFailureThrows() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        let call = Task { try await client.callServiceRaw("/does/not/exist") }
        #expect(await mock.waitForSent(count: 1))
        let id = try #require(await mock.sentOps().last?["id"]?.stringValue)
        try await mock.push(Fixtures.text("status_or_error_response", id: id))
        await #expect(throws: RosbridgeError.serviceFailed(
            service: "/does/not/exist", message: "Service /does/not/exist does not exist"
        )) {
            _ = try await call.value
        }
        await client.disconnect()
    }

    @Test func serviceTimeout() async throws {
        let (client, _) = makeClient()
        try await client.connect(to: testURL)
        await #expect(throws: RosbridgeError.timeout("/slow")) {
            _ = try await client.callServiceRaw("/slow", timeout: .milliseconds(50))
        }
        await client.disconnect()
    }

    @Test func callingServiceWhileDisconnectedThrows() async {
        let (client, _) = makeClient()
        await #expect(throws: RosbridgeError.notConnected) {
            _ = try await client.callServiceRaw("/rosapi/topics")
        }
    }

    @Test func reconnectsAndResubscribes() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        let sub = await client.subscribe("/tf", as: TF2Msgs.TFMessage.self)
        #expect(await mock.waitForSent(count: 1))
        let states = await client.states()

        await mock.dropConnection()

        var sawReconnecting = false
        for await s in states {
            if case .reconnecting = s {
                sawReconnecting = true
            }
            if s == .connected, sawReconnecting {
                break
            }
        }
        #expect(await mock.connectAttempts == 2)
        #expect(await mock.waitForSent(count: 2))
        let ops = await mock.sentOps()
        #expect(ops.filter { $0["op"]?.stringValue == "subscribe" && $0["topic"]?.stringValue == "/tf" }
            .count == 2)

        // still delivers after reconnect
        try await mock.push(Fixtures.text("publish_tf"))
        var it = sub.messages.makeAsyncIterator()
        #expect(await it.next()?.transforms.count == 6)
        await client.disconnect()
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let (client, mock) = makeClient(policy: ReconnectPolicy(
            initialDelay: .milliseconds(5), maxDelay: .milliseconds(5), maxAttempts: 2
        ))
        try await client.connect(to: testURL)
        let states = await client.states()
        await mock.setFailConnect(true)
        await mock.dropConnection()
        var final: ConnectionState?
        for await s in states {
            if case .failed = s {
                final = s; break
            }
        }
        #expect(final != nil)
        #expect(await mock.connectAttempts == 3) // 1 initial + 2 retries
    }

    @Test func userDisconnectDoesNotReconnect() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await mock.connectAttempts == 1)
        #expect(await client.state == .disconnected)
    }

    @Test func publishAdvertisesOnce() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: testURL)
        try await client.publish(StdMsgs.StringMessage(data: "a"), to: "/chatter")
        try await client.publish(StdMsgs.StringMessage(data: "b"), to: "/chatter")
        let ops = await mock.sentOps().map { $0["op"]?.stringValue }
        #expect(ops == ["advertise", "publish", "publish"])
        await client.disconnect()
    }
}
