import Foundation
import simd

/// Where `base_link` sits in AR world space: a user-adjustable registration between the AR
/// scene and the real robot, built from an initial placement (raycast hit) plus gizmo nudges.
///
/// Position + yaw only, not a full 6-DOF pose: robots are bolted to a level floor, and the
/// initial placement already comes from a horizontal-plane raycast (gravity-aligned), so pitch
/// and roll aren't a real degree of freedom worth exposing in the UI — see the M4 row in
/// `docs/PLAN.md`. `yaw` is rotation about AR's `+Y` (up), expressed in AR-world convention
/// (not yet rotated into ROS axes — that conversion happens separately via `FrameConventions`
/// when a point is actually registered, so this type stays agnostic of it).
public struct AlignmentTransform: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var yaw: Float

    public init(position: SIMD3<Float> = .zero, yaw: Float = 0) {
        self.position = position
        self.yaw = yaw
    }

    /// The AR-world transform this alignment implies: rotate about `+Y` by `yaw`, then
    /// translate to `position`.
    public var transform: simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    /// Seeds an alignment from a placement's AR-world transform (e.g. a raycast hit). Only an
    /// approximate starting yaw — ARKit's horizontal-plane raycast heading isn't meaningful,
    /// the gizmo is what actually gets it right.
    public static func from(worldTransform t: simd_float4x4) -> AlignmentTransform {
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let xAxis = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let yaw = atan2(-xAxis.z, xAxis.x)
        return AlignmentTransform(position: position, yaw: yaw)
    }

    /// A pan gesture's delta, expressed in AR world space.
    public func translated(by delta: SIMD3<Float>) -> AlignmentTransform {
        AlignmentTransform(position: position + delta, yaw: yaw)
    }

    /// Moves by `(x, z)` expressed in the alignment's OWN local frame (rotated by the current
    /// `yaw`), not AR world axes — so "move along local X" means the same physical direction
    /// regardless of how the robot is currently rotated, the way dragging a block by its own
    /// axis handles does in a typical AR placement UI. Used by the axis-constrained gizmo: the
    /// user picks an axis button, then a single plain screen-space drag (not a 3D floor
    /// raycast — see the M4 testing notes on why raycasting the touch point was unreliable)
    /// moves along just that axis.
    public func translatedLocally(byX dx: Float = 0, byZ dz: Float = 0) -> AlignmentTransform {
        let worldDelta = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(SIMD3(dx, 0, dz))
        return translated(by: worldDelta)
    }

    /// A rotate gesture's delta, in radians about `+Y`.
    public func rotated(byYaw delta: Float) -> AlignmentTransform {
        AlignmentTransform(position: position, yaw: yaw + delta)
    }

    /// Re-expresses an AR-world point relative to this alignment, i.e. in `base_link`'s own
    /// frame (still AR axis convention — `FrameConventions.toROS` is a separate step).
    public func pointInBaseLink(_ worldPoint: SIMD3<Float>) -> SIMD3<Float> {
        let v = transform.inverse * SIMD4(worldPoint, 1)
        return SIMD3(v.x, v.y, v.z)
    }
}
