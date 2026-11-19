import LiDARScan
import simd

/// A box defined in `base_link` (ROS axes, metres): centre, half-extents, and a yaw about base Z.
/// The one type behind the scan crop box and the exclusion boxes — both are attached to the
/// robot, so they move with its alignment.
public struct BaseLinkBox: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var half: SIMD3<Float>
    public var yaw: Float

    public init(center: SIMD3<Float>, half: SIMD3<Float>, yaw: Float = 0) {
        self.center = center
        self.half = half
        self.yaw = yaw
    }

    /// The box's own frame in base_link: rotate about Z by `yaw`, then translate to `center`.
    public var baseLinkFromBox: simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 0, 1)))
        m.columns.3 = SIMD4(center, 1)
        return m
    }

    /// The box's own axis `i` (0 = X, 1 = Y, 2 = Z) expressed in base_link — the direction a
    /// Move/Size drag along that axis acts in.
    public func axisInBaseLink(_ i: Int) -> SIMD3<Float> {
        var local = SIMD3<Float>.zero
        local[i] = 1
        return simd_quatf(angle: yaw, axis: SIMD3(0, 0, 1)).act(local)
    }

    /// Placed in AR world for the given robot alignment, ready for `SceneFilter`.
    public func oriented(in alignment: AlignmentTransform) -> OrientedBox {
        OrientedBox(worldFromBox: alignment.worldFromBaseLink * baseLinkFromBox, min: -half, max: half)
    }
}
