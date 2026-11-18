import LiDARScan
import simd

/// Turns a raw AR-world `PointCloud` (as captured straight off `ARMeshAnchor` vertices) into
/// one expressed in ROS axis convention, optionally also registered against an
/// `AlignmentTransform` so it lands in `base_link` rather than an arbitrary AR session origin.
/// Pure point-cloud math — no ARKit/RealityKit dependency — so it's testable here rather than
/// in the app target, per CONTRIBUTING.md's "no logic that belongs in a package" rule.
public enum CloudRegistration {
    /// `cloud`'s raw AR-world points re-expressed relative to `alignment` (i.e. in `base_link`)
    /// and rotated into ROS axis convention.
    public static func registering(_ cloud: PointCloud, against alignment: AlignmentTransform) -> PointCloud {
        mapPoints(cloud) { FrameConventions.toROS(point: alignment.pointInBaseLink($0)) }
    }

    /// `cloud`'s raw AR-world points rotated into ROS axis convention only, with no
    /// registration — the unregistered fallback when nothing has been aligned yet.
    public static func rotatedToROSAxes(_ cloud: PointCloud) -> PointCloud {
        mapPoints(cloud) { FrameConventions.toROS(point: $0) }
    }

    private static func mapPoints(
        _ cloud: PointCloud,
        _ transform: (SIMD3<Float>) -> SIMD3<Float>
    ) -> PointCloud {
        guard !cloud.isEmpty else { return cloud }
        var x = [Float](); var y = [Float](); var z = [Float]()
        x.reserveCapacity(cloud.count); y.reserveCapacity(cloud.count); z.reserveCapacity(cloud.count)
        for i in 0 ..< cloud.count {
            let p = transform(cloud.point(at: i))
            x.append(p.x); y.append(p.y); z.append(p.z)
        }
        return PointCloud(x: x, y: y, z: z, confidence: cloud.confidence, color: cloud.color)
    }
}
