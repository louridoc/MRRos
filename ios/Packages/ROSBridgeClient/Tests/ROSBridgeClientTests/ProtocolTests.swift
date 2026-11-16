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
        let data = Data(try Fixtures.text("publish_joint_states").utf8)
        #expect(try IncomingFrame.decode(data).knownOp == .publish)
        let js = try ROSJSON.decode(PublishEnvelope<SensorMsgs.JointState>.self, from: data).msg
        #expect(js.name == ["J1", "J2", "J3", "J4", "J5", "J6"])
        #expect(js.position.count == 6)
    }

    @Test func recordedTFDecodesToMessage() throws {
        let data = Data(try Fixtures.text("publish_tf").utf8)
        let tf = try ROSJSON.decode(PublishEnvelope<TF2Msgs.TFMessage>.self, from: data).msg
        #expect(tf.transforms.count == 6)
        #expect(tf.transforms.first?.header.frameId == "base_link")
        #expect(tf.transforms.first?.childFrameId == "J1_link")
    }

    @Test func recordedRobotDescriptionIsURDF() throws {
        let data = Data(try Fixtures.text("publish_robot_description").utf8)
        let s = try ROSJSON.decode(PublishEnvelope<StdMsgs.StringMessage>.self, from: data).msg
        #expect(s.data.contains("<robot name=\"crx30ia\""))
    }

    @Test func recordedServiceErrorHasStringValues() throws {
        let data = Data(try Fixtures.text("status_or_error_response").utf8)
        let frame = try IncomingFrame.decode(data)
        #expect(frame.result == false)
        let values = try JSONDecoder().decode(ServiceValuesFrame.self, from: data).values
        #expect(values?.stringValue?.contains("does not exist") == true)
    }

    @Test func statusFrameCarriesMessage() throws {
        let data = Data(#"{"op":"status","level":"error","msg":"boom"}"#.utf8)
        #expect(try IncomingFrame.decode(data).knownOp == .status)
        #expect(try JSONDecoder().decode(StatusFrame.self, from: data).msg == "boom")
    }

    @Test func topicsResponseZipsNamesAndTypes() throws {
        let data = Data(try Fixtures.text("service_response_topics").utf8)
        let values = try #require(try JSONDecoder().decode(ServiceValuesFrame.self, from: data).values)
        let r = try values.decode(as: TopicsResponse.self)
        #expect(r.infos.contains(TopicInfo(name: "/joint_states", type: "sensor_msgs/msg/JointState")))
        #expect(r.infos.count == 8)
    }
}
