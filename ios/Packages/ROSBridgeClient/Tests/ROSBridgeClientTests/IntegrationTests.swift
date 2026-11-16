import Foundation
@testable import ROSBridgeClient
import ROSMessages
import Testing

/// Runs only against a live bringup: `MRROS_IT_ROSBRIDGE=ws://localhost:9090` (see tools/it.sh).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MRROS_IT_ROSBRIDGE"] != nil))
struct IntegrationTests {
    private var url: URL {
        URL(string: ProcessInfo.processInfo.environment["MRROS_IT_ROSBRIDGE"] ?? "")!
    }

    @Test func listsBringupTopics() async throws {
        let client = RosbridgeClient(reconnect: .none)
        try await client.connect(to: url)
        let topics = try await client.topics()
        let names = Set(topics.map(\.name))
        #expect(names.isSuperset(of: ["/joint_states", "/tf", "/tf_static", "/robot_description"]))
        await client.disconnect()
    }

    @Test func receivesJointStatesAndLatchedRobotDescription() async throws {
        let client = RosbridgeClient(reconnect: .none)
        try await client.connect(to: url)

        let js = await client.subscribe("/joint_states", as: SensorMsgs.JointState.self)
        var jsIt = js.messages.makeAsyncIterator()
        let first = try #require(await jsIt.next())
        #expect(first.name.count == 6)

        let rd = await client.subscribe("/robot_description", as: StdMsgs.StringMessage.self)
        var rdIt = rd.messages.makeAsyncIterator()
        let urdf = try #require(await rdIt.next())
        #expect(urdf.data.contains("<robot"))

        js.cancel()
        rd.cancel()
        await client.disconnect()
    }
}
