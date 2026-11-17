import Foundation
import simd

/// THE conversion between ROS and ARKit/RealityKit coordinate conventions. Nothing else in the
/// app may swap axes (see CONTRIBUTING.md).
///
/// - ROS / URDF: right-handed, **+Z up**, +X forward, +Y left.
/// - ARKit / RealityKit: right-handed, **+Y up**, −Z forward, +X right.
///
/// We use the rotation of −90° about X: ROS X → AR X, ROS Y → AR −Z, ROS Z → AR +Y.
/// It is a proper rotation (det = +1), so handedness, distances and angles are preserved;
/// where the robot "faces" in the room is decided later by the alignment transform, not here.
public enum FrameConventions {
    /// Maps ROS coordinates to AR coordinates (rotation only).
    public static let rosToAR: simd_double4x4 = {
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4(1, 0, 0, 0) // ROS X → AR X
        m.columns.1 = SIMD4(0, 0, -1, 0) // ROS Y → AR −Z
        m.columns.2 = SIMD4(0, 1, 0, 0) // ROS Z → AR +Y
        return m
    }()

    /// Maps AR coordinates to ROS coordinates (the inverse rotation).
    public static let arToROS: simd_double4x4 = rosToAR.transpose

    public static let rosToARFloat = simd_float4x4(
        SIMD4<Float>(rosToAR.columns.0), SIMD4<Float>(rosToAR.columns.1),
        SIMD4<Float>(rosToAR.columns.2), SIMD4<Float>(rosToAR.columns.3)
    )
    public static let arToROSFloat = rosToARFloat.transpose

    // MARK: Points and directions

    public static func toAR(point p: SIMD3<Double>) -> SIMD3<Double> {
        let v = rosToAR * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    public static func toROS(point p: SIMD3<Double>) -> SIMD3<Double> {
        let v = arToROS * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    // MARK: Full transforms

    /// A pose expressed in ROS coordinates (e.g. a link in `base_link`) becomes the same pose
    /// expressed in AR coordinates: `R · T · Rᵀ`.
    public static func toAR(transform t: simd_double4x4) -> simd_double4x4 {
        rosToAR * t * arToROS
    }

    public static func toROS(transform t: simd_double4x4) -> simd_double4x4 {
        arToROS * t * rosToAR
    }

    public static func toAR(rotation q: simd_quatd) -> simd_quatd {
        simd_quatd(rosToAR) * q * simd_quatd(arToROS)
    }
}
