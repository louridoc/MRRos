import Foundation
import simd
import Testing
@testable import URDFKit

let twoJointURDF = """
<?xml version="1.0"?>
<robot name="two">
  <material name="steel"><color rgba="0.5 0.5 0.6 1"/></material>
  <link name="base">
    <visual>
      <origin xyz="0 0 0.05" rpy="0 0 0"/>
      <geometry><box size="0.2 0.2 0.1"/></geometry>
      <material name="steel"/>
    </visual>
  </link>
  <link name="arm">
    <visual>
      <geometry><mesh filename="package://two/meshes/arm.dae" scale="0.001 0.001 0.001"/></geometry>
      <material name="orange"><color rgba="1 0.5 0 1"/></material>
    </visual>
    <collision><geometry><cylinder radius="0.02" length="0.5"/></geometry></collision>
  </link>
  <link name="tool"/>
  <link name="tool_mimic"/>
  <joint name="shoulder" type="revolute">
    <parent link="base"/><child link="arm"/>
    <origin xyz="0 0 0.1" rpy="0 0 0"/>
    <axis xyz="0 0 1"/>
    <limit lower="-3.14" upper="3.14" effort="10" velocity="1"/>
  </joint>
  <joint name="slide" type="prismatic">
    <parent link="arm"/><child link="tool"/>
    <origin xyz="0.5 0 0" rpy="0 0 0"/>
    <axis xyz="1 0 0"/>
    <limit lower="0" upper="0.3" effort="10" velocity="1"/>
  </joint>
  <joint name="slide_mimic" type="prismatic">
    <parent link="arm"/><child link="tool_mimic"/>
    <origin xyz="0 0.5 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <mimic joint="slide" multiplier="2" offset="0.01"/>
  </joint>
</robot>
"""

struct ParserTests {
    @Test func parsesLinksJointsAndMaterials() throws {
        let r = try URDFParser.parse(twoJointURDF)
        #expect(r.name == "two")
        #expect(r.rootLink == "base")
        #expect(r.links.count == 4)
        #expect(r.joints.map(\.name) == ["shoulder", "slide", "slide_mimic"])
        #expect(r.actuatedJointNames == ["shoulder", "slide"])
        #expect(r.linkNamesInTreeOrder() == ["base", "arm", "tool", "tool_mimic"])
        #expect(r.baseFrame == "base", "no link literally named base_link -> falls back to rootLink")

        let base = try #require(r.links["base"])
        #expect(base.visuals.first?.material?.rgba == SIMD4(0.5, 0.5, 0.6, 1)) // resolved by name
        #expect(base.visuals.first?.geometry == .box(size: SIMD3(0.2, 0.2, 0.1)))
        #expect(base.visuals.first?.origin.xyz == SIMD3(0, 0, 0.05))

        let arm = try #require(r.links["arm"])
        #expect(arm.visuals.first?.geometry == .mesh(
            filename: "package://two/meshes/arm.dae",
            scale: SIMD3(repeating: 0.001)
        ))
        #expect(arm.visuals.first?.material?.rgba == SIMD4(1, 0.5, 0, 1))
        #expect(arm.collisions.first?.geometry == .cylinder(radius: 0.02, length: 0.5))
        #expect(r.visualMeshFilenames == ["package://two/meshes/arm.dae"])

        let shoulder = try #require(r.jointsByName["shoulder"])
        #expect(shoulder.type == .revolute)
        #expect(shoulder.axis == SIMD3(0, 0, 1))
        #expect(shoulder.limit?.upper == 3.14)
        #expect(r.jointsByName["slide_mimic"]?.mimic == Mimic(joint: "slide", multiplier: 2, offset: 0.01))
    }

    @Test func rejectsNonRobot() {
        #expect(throws: URDFError.notARobot(rootElement: "launch")) {
            try URDFParser.parse("<launch/>")
        }
    }

    @Test func rejectsMalformedXML() {
        #expect(throws: URDFError.self) {
            try URDFParser.parse("<robot name=\"x\"><link name=\"a\"></robot>")
        }
    }

    @Test func rejectsUnknownLinkAndBadVectors() {
        #expect(throws: URDFError.unknownLink(joint: "j", link: "ghost")) {
            try URDFParser.parse("""
            <robot name="x"><link name="a"/>
            <joint name="j" type="fixed"><parent link="a"/><child link="ghost"/></joint></robot>
            """)
        }
        #expect(throws: URDFError.badVector(element: "origin", attribute: "xyz", value: "1 2")) {
            try URDFParser.parse("""
            <robot name="x"><link name="a"/><link name="b"/>
            <joint name="j" type="fixed"><origin xyz="1 2"/><parent link="a"/><child link="b"/></joint></robot>
            """)
        }
    }

    @Test func rejectsMultipleRootsAndCycles() {
        #expect(throws: URDFError.multipleRootLinks(["a", "b"])) {
            try URDFParser.parse("<robot name=\"x\"><link name=\"a\"/><link name=\"b\"/></robot>")
        }
        #expect(throws: URDFError.self) {
            try URDFParser.parse("""
            <robot name="x"><link name="r"/><link name="a"/><link name="b"/>
            <joint name="j0" type="fixed"><parent link="r"/><child link="a"/></joint>
            <joint name="j1" type="fixed"><parent link="a"/><child link="b"/></joint>
            <joint name="j2" type="fixed"><parent link="b"/><child link="a"/></joint></robot>
            """)
        }
    }

    @Test func unknownJointTypeIsAnError() {
        #expect(throws: URDFError.unknownJointType("bendy")) {
            try URDFParser.parse("""
            <robot name="x"><link name="a"/><link name="b"/>
            <joint name="j" type="bendy"><parent link="a"/><child link="b"/></joint></robot>
            """)
        }
    }

    /// Mirrors FANUC CRX's xacro: a synthetic `world` root offset from the actual robot base via
    /// a fixed "pedestal" joint. `baseFrame` must resolve to `base_link`, not the structural root.
    @Test func baseFramePrefersBaseLinkOverStructuralRoot() throws {
        let r = try URDFParser.parse("""
        <robot name="pedestal">
          <link name="world"/><link name="base_link"/><link name="ee_link"/>
          <joint name="base_joint" type="fixed">
            <origin xyz="0 0 0.75" rpy="0 0 0"/><parent link="world"/><child link="base_link"/>
          </joint>
          <joint name="J1" type="revolute">
            <parent link="base_link"/><child link="ee_link"/><axis xyz="0 0 1"/>
            <limit lower="-1" upper="1" effort="1" velocity="1"/>
          </joint>
        </robot>
        """)
        #expect(r.rootLink == "world")
        #expect(r.baseFrame == "base_link")
    }
}

struct KinematicsTests {
    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tol: Double = 1e-12) -> Bool {
        simd_length(a - b) < tol
    }

    @Test func rpyIsFixedAxisXYZ() {
        // yaw 90°: +X → +Y
        let o = Origin(rpy: SIMD3(0, 0, .pi / 2))
        let x = o.matrix * SIMD4<Double>(1, 0, 0, 0)
        #expect(close(SIMD3(x.x, x.y, x.z), SIMD3(0, 1, 0)))
        // roll 90° then yaw 90°: R = Rz·Rx; +Y → (roll) +Z → (yaw) +Z
        let o2 = Origin(rpy: SIMD3(.pi / 2, 0, .pi / 2))
        let y = o2.matrix * SIMD4<Double>(0, 1, 0, 0)
        #expect(close(SIMD3(y.x, y.y, y.z), SIMD3(0, 0, 1)))
        // pitch 90°: +X → -Z
        let o3 = Origin(rpy: SIMD3(0, .pi / 2, 0))
        let z = o3.matrix * SIMD4<Double>(1, 0, 0, 0)
        #expect(close(SIMD3(z.x, z.y, z.z), SIMD3(0, 0, -1)))
    }

    @Test func forwardKinematicsByHand() throws {
        let r = try URDFParser.parse(twoJointURDF)
        let t = r.linkTransforms(jointPositions: ["shoulder": .pi / 2, "slide": 0.1])
        // arm: at z=0.1, rotated 90° about Z
        #expect(try close(#require(t["arm"]?.translation), SIMD3(0, 0, 0.1)))
        // tool: arm frame + (0.5 + 0.1) along arm's X, which is world +Y after the rotation
        #expect(try close(#require(t["tool"]?.translation), SIMD3(0, 0.6, 0.1)))
        // mimic: 2*0.1 + 0.01 = 0.21 along arm's Y (= world -X), from arm offset (0, 0.5) → world (-0.5, 0)
        #expect(try close(#require(t["tool_mimic"]?.translation), SIMD3(-0.5 - 0.21, 0, 0.1)))
        // base is identity
        #expect(t["base"] == matrix_identity_double4x4)
    }

    @Test func missingPositionsDefaultToZero() throws {
        let r = try URDFParser.parse(twoJointURDF)
        let t = r.linkTransforms(jointPositions: [:])
        #expect(try close(#require(t["tool"]?.translation), SIMD3(0.5, 0, 0.1)))
    }

    @Test func linkTransformsRelativeToRebasesWithoutChangingRelativePoses() throws {
        let r = try URDFParser.parse(twoJointURDF)
        let positions = ["shoulder": Double.pi / 2, "slide": 0.1]
        let rootRelative = r.linkTransforms(jointPositions: positions)
        let armRelative = r.linkTransforms(jointPositions: positions, relativeTo: "arm")

        #expect(armRelative["arm"] == matrix_identity_double4x4, "the reference frame is identity")
        // "base" sits one fixed joint away from "arm" in the root tree; rebasing must move it,
        // not leave it at the root-relative pose.
        #expect(armRelative["base"] != rootRelative["base"])
        // But the pose of "tool" AS SEEN FROM "arm" must be unchanged by the rebasing (it was
        // already expressed relative to "arm" in the original FK, just also offset by "arm"'s own
        // root-relative pose on top — rebasing only removes that outer offset).
        let expectedToolFromArm = try #require(rootRelative["arm"]?.inverse) * #require(rootRelative["tool"])
        #expect(try close(#require(armRelative["tool"]?.translation), expectedToolFromArm.translation))
    }

    @Test func linkTransformsRelativeToUnknownFrameIsANoOp() throws {
        let r = try URDFParser.parse(twoJointURDF)
        let rootRelative = r.linkTransforms(jointPositions: ["shoulder": 0.3])
        let sameAsRoot = r.linkTransforms(jointPositions: ["shoulder": 0.3], relativeTo: "no-such-link")
        #expect(sameAsRoot["arm"] == rootRelative["arm"])
    }
}
