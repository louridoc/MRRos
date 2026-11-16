@testable import AppCore
import Foundation
import ROSBridgeClient
import ROSMessages
import Testing

private let jointStatesFrame = """
{"op":"publish","topic":"/joint_states","msg":{"header":{"stamp":{"sec":1,"nanosec":0},"frame_id":""},
 "name":["J1","J2"],"position":[0.25,-0.5],"velocity":[],"effort":[]}}
"""
private let robotDescriptionFrame = """
{"op":"publish","topic":"/robot_description","msg":{"data":"<?xml version=\\"1.0\\"?>\\n<robot name=\\"crx30ia\\" xmlns:xacro=\\"x\\">\\n</robot>"}}
"""

@MainActor
struct ROSSessionTests {
    private func makeSession() -> (ROSSession, MockWebSocketTransport, UserDefaults) {
        let mock = MockWebSocketTransport()
        let defaults = UserDefaults(suiteName: "ROSSessionTests-\(UUID().uuidString)")!
        let session = ROSSession(transportFactory: { _ in mock }, reconnect: .none, defaults: defaults)
        session.settings = ConnectionSettings(host: "mock", port: 9090)
        return (session, mock, defaults)
    }

    @Test func settingsPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "ROSSessionTests-persist-\(UUID().uuidString)"))
        ConnectionSettings(host: "10.0.0.5", port: 9091).save(to: defaults)
        #expect(ConnectionSettings.load(from: defaults) == ConnectionSettings(host: "10.0.0.5", port: 9091))
        #expect(ConnectionSettings(host: " ", port: 9090).url == nil)
        #expect(ConnectionSettings(host: "h", port: 70000).url == nil)
        #expect(ConnectionSettings(host: "lab.local", port: 9090).url?
            .absoluteString == "ws://lab.local:9090")
    }

    @Test func connectSubscribesAndUpdatesJointsAndRobotName() async throws {
        let (session, mock, _) = makeSession()
        let connecting = Task { await session.connect() }

        // connect() awaits /rosapi/topics; answer it so connect completes.
        #expect(await mock.waitForSent(count: 3))
        let ops = await mock.sentOps()
        let subTopics = Set(ops
            .compactMap { $0["op"]?.stringValue == "subscribe" ? $0["topic"]?.stringValue : nil })
        #expect(subTopics == ["/joint_states", "/robot_description"])
        let svc = try #require(ops.first { $0["op"]?.stringValue == "call_service" })
        let id = try #require(svc["id"]?.stringValue)
        await mock
            .push(
                #"{"op":"service_response","id":"\#(id)","service":"/rosapi/topics","result":true,"values":{"topics":["/tf"],"types":["tf2_msgs/msg/TFMessage"]}}"#
            )
        await connecting.value

        #expect(session.isConnected)
        #expect(session.topics.map(\.name) == ["/tf"])

        await mock.push(jointStatesFrame)
        await mock.push(robotDescriptionFrame)
        for _ in 0 ..< 100 where session.robotName == nil || session.jointState == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.jointState?.positionsByName["J2"] == -0.5)
        #expect(session.robotName == "crx30ia")

        await session.disconnect()
        #expect(session.state == .disconnected)
        #expect(session.jointState == nil)
        #expect(session.robotName == nil, "previous bridge's identity must not survive a disconnect")
        #expect(session.urdf == nil)
        #expect(session.topics.isEmpty)
    }

    @Test func connectFailureSetsError() async {
        let (session, mock, _) = makeSession()
        await mock.setFailConnect(true)
        await session.connect()
        #expect(session.lastError != nil)
        #expect(!session.isConnected)
    }

    @Test func invalidSettingsDoNotConnect() async {
        let (session, mock, _) = makeSession()
        session.settings = ConnectionSettings(host: "", port: 9090)
        await session.connect()
        #expect(session.lastError == "Invalid host or port")
        #expect(await mock.connectAttempts == 0)
    }

    @Test func robotNameParsing() {
        #expect(ROSSession.robotName(in: "<robot name=\"ur30\">") == "ur30")
        #expect(ROSSession.robotName(in: "<robot xmlns:xacro=\"x\" name=\"crx20ia_l\">") == "crx20ia_l")
        #expect(ROSSession.robotName(in: "<link name=\"base\"/>") == nil)
        // `filename=` must not be mistaken for `name=`
        #expect(ROSSession.robotName(in: "<robot filename=\"ur10e.urdf\" name=\"ur10e\">") == "ur10e")
        #expect(ROSSession.robotName(in: "<robot filename=\"x\">") == nil)
    }
}
