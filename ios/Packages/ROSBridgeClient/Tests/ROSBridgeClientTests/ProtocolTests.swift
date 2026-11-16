import Foundation
@testable import ROSBridgeClient
import ROSMessages
import Testing

struct ProtocolTests {
    @Test func subscribeOpEncodesRosbridgeKeys() throws {
        let text = try OutgoingOp.subscribe(
            id: "sub_1", topic: "/joint_states", type: "sensor_msgs/msg/JointState",
            throttleRate: 50, queueLength: 2
        ).encodedText()
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["op"] as? String == "subscribe")
        #expect(obj?["throttle_rate"] as? Int == 50)
        #expect(obj?["queue_length"] as? Int == 2)
        #expect(obj?["type"] as? String == "sensor_msgs/msg/JointState")
    }

    @Test func callServiceOmitsNilFields() throws {
        let text = try OutgoingOp.callService(id: "svc_1", service: "/rosapi/topics", type: nil, args: nil)
            .encodedText()
        #expect(!text.contains("\"type\""))
        #expect(!text.contains("\"args\""))
        #expect(text.contains("\"op\":\"call_service\""))
    }

    @Test func publishOpCarriesSnakeCaseMessage() throws {
        let msg = try JSONValue.from(StdMsgs.Header(frameId: "map"))
        let text = try OutgoingOp.publish(topic: "/x", msg: msg).encodedText()
        #expect(text.contains("\"frame_id\":\"map\""))
    }

    @Test(arguments: [
        "service_response_topics", "publish_joint_states", "publish_tf", "publish_tf_static",
        "publish_robot_description", "service_response_get_parameters", "status_or_error_response",
    ])
    func decodesRecordedFrames(name: String) throws {
        let frame = try IncomingFrame.decode(Fixtures.text(name))
        #expect(frame.knownOp != nil, "unknown op in \(name)")
    }

    @Test func recordedJointStateDecodesToMessage() throws {
        let frame = try IncomingFrame.decode(Fixtures.text("publish_joint_states"))
        let js = try #require(frame.msg).decode(as: SensorMsgs.JointState.self)
        #expect(js.name == ["J1", "J2", "J3", "J4", "J5", "J6"])
        #expect(js.position.count == 6)
    }

    @Test func recordedTFDecodesToMessage() throws {
        let frame = try IncomingFrame.decode(Fixtures.text("publish_tf"))
        let tf = try #require(frame.msg).decode(as: TF2Msgs.TFMessage.self)
        #expect(tf.transforms.count == 6)
        #expect(tf.transforms.first?.header.frameId == "base_link")
        #expect(tf.transforms.first?.childFrameId == "J1_link")
    }

    @Test func recordedRobotDescriptionIsURDF() throws {
        let frame = try IncomingFrame.decode(Fixtures.text("publish_robot_description"))
        let s = try #require(frame.msg).decode(as: StdMsgs.StringMessage.self)
        #expect(s.data.contains("<robot name=\"crx30ia\""))
    }

    @Test func recordedServiceErrorHasStringValues() throws {
        let frame = try IncomingFrame.decode(Fixtures.text("status_or_error_response"))
        #expect(frame.result == false)
        #expect(frame.values?.stringValue?.contains("does not exist") == true)
    }

    @Test func topicsResponseZipsNamesAndTypes() throws {
        let frame = try IncomingFrame.decode(Fixtures.text("service_response_topics"))
        let r = try #require(frame.values).decode(as: TopicsResponse.self)
        #expect(r.infos.contains(TopicInfo(name: "/joint_states", type: "sensor_msgs/msg/JointState")))
        #expect(r.infos.count == 8)
    }
}
