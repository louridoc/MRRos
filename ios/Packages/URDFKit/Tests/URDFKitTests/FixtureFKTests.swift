import Foundation
import ROSMessages
import simd
import Testing
@testable import URDFKit

/// Replays recorded bringups: our FK from the URDF + /joint_states must reproduce what
/// robot_state_publisher put on /tf and /tf_static, for every link, for every priority robot.
struct FixtureFKTests {
    static let robots = ["crx30ia", "crx20ial", "ur30", "ur20", "ur10e"]

    struct Fixture {
        let robot: URDFRobot
        let jointStates: SensorMsgs.JointState
        let tf: [GeometryMsgs.TransformStamped]
        let pose: [Double]
    }

    static func load(_ name: String) throws -> Fixture {
        func url(_ file: String) throws -> URL {
            let sub = "Fixtures/\(name)"
            let parts = file.split(separator: ".").map(String.init)
            guard let u = Bundle.module
                .url(forResource: parts[0], withExtension: parts[1], subdirectory: sub)
            else {
                throw NSError(
                    domain: "fixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(sub)/\(file) missing"]
                )
            }
            return u
        }
        let robot = try URDFParser.parse(Data(contentsOf: url("robot.urdf")))
        let js = try ROSJSON.decode(
            SensorMsgs.JointState.self,
            from: Data(contentsOf: url("joint_states.json"))
        )
        let tf = try ROSJSON.decode(TF2Msgs.TFMessage.self, from: Data(contentsOf: url("tf.json")))
        let tfStatic = try ROSJSON.decode(
            TF2Msgs.TFMessage.self,
            from: Data(contentsOf: url("tf_static.json"))
        )
        struct Pose: Decodable { let positions: [Double] }
        let pose = try JSONDecoder().decode(Pose.self, from: Data(contentsOf: url("pose.json"))).positions
        return Fixture(robot: robot, jointStates: js, tf: tfStatic.transforms + tf.transforms, pose: pose)
    }

    /// child link → pose in root frame, composed from the recorded parent→child transforms.
    static func tfPoses(_ tf: [GeometryMsgs.TransformStamped], root: String) -> [String: simd_double4x4] {
        let parentOf = Dictionary(tf.map { ($0.childFrameId, $0) }, uniquingKeysWith: { _, new in new })
        var out: [String: simd_double4x4] = [root: matrix_identity_double4x4]
        func pose(_ link: String) -> simd_double4x4? {
            if let p = out[link] {
                return p
            }
            guard let t = parentOf[link], let parentPose = pose(t.header.frameId) else { return nil }
            let q = simd_quatd(
                ix: t.transform.rotation.x,
                iy: t.transform.rotation.y,
                iz: t.transform.rotation.z,
                r: t.transform.rotation.w
            )
            var m = simd_double4x4(q)
            m.columns.3 = SIMD4(
                t.transform.translation.x,
                t.transform.translation.y,
                t.transform.translation.z,
                1
            )
            let p = parentPose * m
            out[link] = p
            return p
        }
        for t in tf {
            _ = pose(t.childFrameId)
        }
        return out
    }

    @Test(arguments: robots)
    func fixtureIsConsistent(name: String) throws {
        let f = try Self.load(name)
        #expect(f.jointStates.position == f.pose, "recorded pose must be the requested constant pose")
        #expect(
            Set(f.jointStates.name) == Set(f.robot.actuatedJointNames),
            "joint_states vs URDF actuated joints"
        )
        #expect(f.robot.visualMeshFilenames.count >= 6, "\(name) should reference visual meshes")
    }

    @Test(arguments: robots)
    func forwardKinematicsMatchesRobotStatePublisher(name: String) throws {
        let f = try Self.load(name)
        let ours = f.robot.linkTransforms(jointPositions: f.jointStates.positionsByName)
        let theirs = Self.tfPoses(f.tf, root: f.robot.rootLink)

        var compared = 0
        var worstPos = 0.0
        var worstRot = 0.0
        for (link, expected) in theirs {
            guard let got = ours[link] else {
                Issue.record("\(name): link \(link) on /tf but not in our tree")
                continue
            }
            let dPos = simd_length(got.translation - expected.translation)
            // quaternion distance, sign-insensitive
            let dRot = 1 - abs(simd_dot(got.rotation.vector, expected.rotation.vector))
            worstPos = max(worstPos, dPos)
            worstRot = max(worstRot, dRot)
            #expect(dPos < 1e-4, "\(name)/\(link): position off by \(dPos) m")
            #expect(dRot < 1e-6, "\(name)/\(link): rotation off by \(dRot)")
            compared += 1
        }
        #expect(compared >= 7, "\(name): only \(compared) links compared")
        print("FK \(name): \(compared) links, worst Δpos=\(worstPos) m, worst Δrot=\(worstRot)")
    }
}
