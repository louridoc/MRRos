import Foundation
import simd

public extension URDFRobot {
    /// Pose of every link in the root-link frame for the given joint positions.
    /// Missing positions are 0; mimic joints follow their source joint.
    func linkTransforms(jointPositions: [String: Double]) -> [String: simd_double4x4] {
        var out: [String: simd_double4x4] = [rootLink: matrix_identity_double4x4]
        var stack: [(link: String, pose: simd_double4x4)] = [(rootLink, matrix_identity_double4x4)]
        while let (link, pose) = stack.popLast() {
            for joint in childJoints[link] ?? [] {
                let q = position(of: joint, in: jointPositions)
                let childPose = pose * joint.transform(position: q)
                out[joint.child] = childPose
                stack.append((joint.child, childPose))
            }
        }
        return out
    }

    /// Transform from a joint's parent link to its child link for the given positions.
    func jointTransform(_ joint: Joint, jointPositions: [String: Double]) -> simd_double4x4 {
        joint.transform(position: position(of: joint, in: jointPositions))
    }

    /// Pose of every link relative to `frame` (identity at `frame` itself) rather than the
    /// structural root. Use this for placement/rendering — see `baseFrame` for why the robot's
    /// *root* and its conventional *base* are not always the same link (e.g. a fixed pedestal
    /// joint hanging `base_link` off a synthetic `world` link).
    func linkTransforms(
        jointPositions: [String: Double],
        relativeTo frame: String
    ) -> [String: simd_double4x4] {
        let rootRelative = linkTransforms(jointPositions: jointPositions)
        guard let framePose = rootRelative[frame] else { return rootRelative } // unknown frame: no-op
        let frameInverse = framePose.inverse
        return rootRelative.mapValues { frameInverse * $0 }
    }

    private func position(of joint: Joint, in positions: [String: Double]) -> Double {
        if let m = joint.mimic {
            return (positions[m.joint] ?? 0) * m.multiplier + m.offset
        }
        return positions[joint.name] ?? 0
    }
}

public extension simd_double4x4 {
    var translation: SIMD3<Double> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    var rotation: simd_quatd {
        simd_quatd(simd_double3x3(
            SIMD3(columns.0.x, columns.0.y, columns.0.z),
            SIMD3(columns.1.x, columns.1.y, columns.1.z),
            SIMD3(columns.2.x, columns.2.y, columns.2.z)
        ))
    }

    /// Lossy conversion for rendering.
    var floatMatrix: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(columns.0), SIMD4<Float>(columns.1), SIMD4<Float>(columns.2), SIMD4<Float>(columns.3)
        )
    }
}
