import Foundation
@testable import ROSMessages
import Testing

struct TimeTests {
    @Test func secondsRoundTrip() {
        let t = ROSTime(seconds: 1_794_796_975.699_432)
        #expect(t.sec == 1_794_796_975)
        #expect(abs(Double(t.nanosec) - 699_432_000) < 1000)
        #expect(abs(t.seconds - 1_794_796_975.699_432) < 1e-6)
    }

    @Test func ordering() {
        #expect(ROSTime(sec: 1, nanosec: 5) < ROSTime(sec: 1, nanosec: 6))
        #expect(ROSTime(sec: 1, nanosec: 999_999_999) < ROSTime(sec: 2, nanosec: 0))
    }
}

struct WireFormatTests {
    /// Verbatim shape of a rosbridge `publish` payload for /joint_states (keys are snake_case).
    static let jointStateJSON = """
    {"header":{"stamp":{"sec":1794796975,"nanosec":699432000},"frame_id":""},
     "name":["J1","J2","J3","J4","J5","J6"],
     "position":[0.1,-0.2,0.3,0.0,0.5,-0.6],"velocity":[],"effort":[]}
    """

    @Test func decodeJointState() throws {
        let js = try ROSJSON.decode(SensorMsgs.JointState.self, from: Data(Self.jointStateJSON.utf8))
        #expect(js.name.count == 6)
        #expect(js.position[1] == -0.2)
        #expect(js.velocity.isEmpty)
        #expect(js.header.stamp.sec == 1_794_796_975)
        #expect(js.positionsByName["J5"] == 0.5)
    }

    @Test func positionsByNameToleratesShortArrays() {
        let js = SensorMsgs.JointState(name: ["a", "b"], position: [1.0])
        #expect(js.positionsByName == ["a": 1.0])
    }

    @Test func transformStampedUsesSnakeCaseKeys() throws {
        let ts = GeometryMsgs.TransformStamped(
            header: .init(stamp: .init(sec: 1, nanosec: 2), frameId: "base_link"),
            childFrameId: "J1",
            transform: .init(translation: .init(x: 1, y: 2, z: 3), rotation: .init())
        )
        let data = try ROSJSON.encode(TF2Msgs.TFMessage(transforms: [ts]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"child_frame_id\":\"J1\""))
        #expect(text.contains("\"frame_id\":\"base_link\""))
        #expect(!text.contains("childFrameId"))

        let back = try ROSJSON.decode(TF2Msgs.TFMessage.self, from: data)
        #expect(back.transforms == [ts])
    }

    @Test func quaternionDefaultsToIdentity() {
        #expect(GeometryMsgs.Quaternion() == .init(x: 0, y: 0, z: 0, w: 1))
    }

    @Test func rosTypeNames() {
        #expect(SensorMsgs.JointState.rosType == "sensor_msgs/msg/JointState")
        #expect(TF2Msgs.TFMessage.rosType == "tf2_msgs/msg/TFMessage")
        #expect(StdMsgs.StringMessage.rosType == "std_msgs/msg/String")
    }
}

struct JSONValueTests {
    @Test func decodesMixedTree() throws {
        let data = Data("""
        {"op":"publish","topic":"/x","msg":{"a":1,"b":[true,null,"s"],"c":{"d":2.5}}}
        """.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(v["op"]?.stringValue == "publish")
        #expect(v["msg"]?["a"]?.doubleValue == 1)
        #expect(v["msg"]?["b"]?.arrayValue?[1] == .null)
        #expect(v["msg"]?["c"]?["d"]?.doubleValue == 2.5)
    }

    @Test func decodeSubtreeAsMessage() throws {
        let data = Data(WireFormatTests.jointStateJSON.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        let js = try v.decode(as: SensorMsgs.JointState.self)
        #expect(js.name.first == "J1")
    }

    @Test func fromEncodableUsesSnakeCase() throws {
        let v = try JSONValue.from(StdMsgs.Header(frameId: "map"))
        #expect(v["frame_id"]?.stringValue == "map")
        #expect(v["stamp"]?["sec"]?.doubleValue == 0)
    }
}
