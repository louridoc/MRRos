import simd

/// An axis-aligned box in its own frame, placed in the world by a rigid transform — the one
/// primitive behind both scan filters: each robot link's bounds (at its current pose) and the
/// user's crop box. Stores `boxFromWorld` (the inverse placement) so a containment test is one
/// matrix-vector product per point.
public struct OrientedBox: Sendable, Equatable {
    public let boxFromWorld: simd_float4x4
    public let min: SIMD3<Float>
    public let max: SIMD3<Float>

    public init(boxFromWorld: simd_float4x4, min: SIMD3<Float>, max: SIMD3<Float>) {
        self.boxFromWorld = boxFromWorld
        self.min = min
        self.max = max
    }

    public init(worldFromBox: simd_float4x4, min: SIMD3<Float>, max: SIMD3<Float>) {
        self.init(boxFromWorld: worldFromBox.inverse, min: min, max: max)
    }

    /// Inclusive; `padding` grows the box equally on every side.
    public func contains(_ worldPoint: SIMD3<Float>, padding: Float = 0) -> Bool {
        let p4 = boxFromWorld * SIMD4(worldPoint, 1)
        let p = SIMD3(p4.x, p4.y, p4.z)
        return all(p .>= min - padding) && all(p .<= max + padding)
    }
}

/// Why a scan point is (or isn't) uploaded.
public enum PointClass: UInt8, Sendable, Equatable {
    case kept
    /// Inside a (padded) robot link box — the scan caught the real robot.
    case robot
    /// Inside a user exclusion box ("drop whatever is in here").
    case excluded
    /// Outside the user's crop box.
    case outsideCrop
}

public enum SceneFilter {
    /// Priority robot > excluded > outsideCrop, so the preview shows the most specific reason a
    /// point is dropped. `crop: nil` means no cropping.
    public static func classify(
        _ cloud: PointCloud,
        crop: OrientedBox?,
        exclusions: [OrientedBox] = [],
        robot: [OrientedBox],
        robotPadding: Float
    ) -> [PointClass] {
        (0 ..< cloud.count).map { i in
            let p = cloud.point(at: i)
            if robot.contains(where: { $0.contains(p, padding: robotPadding) }) {
                return .robot
            }
            if exclusions.contains(where: { $0.contains(p) }) {
                return .excluded
            }
            if let crop, !crop.contains(p) {
                return .outsideCrop
            }
            return .kept
        }
    }
}

public extension PointCloud {
    /// The points whose class equals `wanted`, with every column kept index-aligned.
    func selecting(_ classes: [PointClass], equalTo wanted: PointClass) -> PointCloud {
        precondition(classes.count == count, "one class per point")
        let idx = classes.indices.filter { classes[$0] == wanted }
        return PointCloud(
            x: idx.map { x[$0] }, y: idx.map { y[$0] }, z: idx.map { z[$0] },
            confidence: confidence.map { c in idx.map { c[$0] } },
            color: color.map { c in idx.map { c[$0] } }
        )
    }
}
