import Foundation
@testable import RobotModel
import ROSMessages
import Testing
import URDFKit

private let urdf = """
<robot name="t">
  <link name="base"/><link name="a"/><link name="b"/><link name="c"/>
  <joint name="ur_shoulder_pan_joint" type="revolute">
    <parent link="base"/><child link="a"/><axis xyz="0 0 1"/>
    <limit lower="-1" upper="1" effort="1" velocity="1"/>
  </joint>
  <joint name="ur_elbow_joint" type="continuous"><parent link="a"/><child link="b"/><axis xyz="0 1 0"/></joint>
  <joint name="gripper" type="prismatic">
    <parent link="b"/><child link="c"/><axis xyz="1 0 0"/>
    <limit lower="0" upper="0.05" effort="1" velocity="1"/>
  </joint>
</robot>
"""

struct JointStateMapperTests {
    private func robot() throws -> URDFRobot {
        try URDFParser.parse(urdf)
    }

    @Test func exactNamesApplyAndUnknownAreReported() throws {
        var m = try JointStateMapper(robot: robot())
        let r = m.apply(SensorMsgs.JointState(name: ["ur_shoulder_pan_joint", "ghost"], position: [0.5, 1]))
        #expect(r.applied == 1)
        #expect(r.unknown == ["ghost"])
        #expect(m.positions["ur_shoulder_pan_joint"] == 0.5)
        #expect(m.positions["ur_elbow_joint"] == 0, "untouched joints keep their last value")
    }

    @Test func prefixTolerantMatching() throws {
        var m = try JointStateMapper(robot: robot())
        // message without the URDF's "ur_" prefix
        m.apply(SensorMsgs.JointState(name: ["shoulder_pan_joint", "elbow_joint"], position: [0.2, 0.3]))
        #expect(m.positions["ur_shoulder_pan_joint"] == 0.2)
        #expect(m.positions["ur_elbow_joint"] == 0.3)
        // message with an extra prefix on a plain URDF name
        m.apply(SensorMsgs.JointState(name: ["robot1_gripper"], position: [0.04]))
        #expect(m.positions["gripper"] == 0.04)
    }

    @Test func clampsRevoluteAndPrismaticButNotContinuous() throws {
        var m = try JointStateMapper(robot: robot())
        let r = m.apply(SensorMsgs.JointState(
            name: ["ur_shoulder_pan_joint", "ur_elbow_joint", "gripper"], position: [3.0, 9.0, -1]
        ))
        #expect(m.positions["ur_shoulder_pan_joint"] == 1.0)
        #expect(m.positions["ur_elbow_joint"] == 9.0)
        #expect(m.positions["gripper"] == 0)
        #expect(Set(r.clamped) == ["ur_shoulder_pan_joint", "gripper"])
    }

    @Test func partialAndShortMessagesAreSafe() throws {
        var m = try JointStateMapper(robot: robot())
        m.apply(SensorMsgs.JointState(name: ["gripper"], position: [0.02]))
        m.apply(SensorMsgs.JointState(
            name: ["ur_elbow_joint", "gripper"],
            position: [0.7]
        )) // position shorter than name
        #expect(m.positions["gripper"] == 0.02)
        #expect(m.positions["ur_elbow_joint"] == 0.7)
    }
}

struct JointSmootherTests {
    @Test func convergesTowardsTargets() throws {
        var s = JointSmoother(tau: 0.1)
        s.setTargets(["j": 0])
        s.setTargets(["j": 1])
        s.step(dt: 0.1)
        let after1 = try #require(s.current["j"])
        #expect(after1 > 0.6 && after1 < 0.65, "≈ 1 − e⁻¹ after one time constant")
        for _ in 0 ..< 50 {
            s.step(dt: 0.1)
        }
        #expect(s.current["j"] == 1)
    }

    @Test func firstValueHasNoLagAndZeroTauIsPassThrough() {
        var s = JointSmoother(tau: 0.1)
        s.setTargets(["j": 2])
        #expect(s.current["j"] == 2)
        var p = JointSmoother(tau: 0)
        p.setTargets(["j": 0])
        p.setTargets(["j": 5])
        #expect(p.step(dt: 0.016)["j"] == 5)
    }

    @Test func continuousJointsTakeTheShortArc() throws {
        var s = JointSmoother(tau: 0.05, wrapAroundJoints: ["w"])
        s.setTargets(["w": 3.0])
        s.setTargets(["w": -3.0]) // 0.28 rad away across ±π, not 6 rad the long way
        s.step(dt: 0.01)
        #expect(try #require(s.current["w"]) > 3.0, "moves up through π rather than down")
    }
}
