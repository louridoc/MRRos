import Foundation

/// A static point cloud, struct-of-arrays so accumulation (appending a new ARKit frame's worth
/// of points) and the voxel filter stay cheap. `confidence`/`color`, when present, always have
/// exactly `count` elements — enforced by every API in this package, not just assumed.
public struct PointCloud: Sendable, Equatable {
    public var x: [Float]
    public var y: [Float]
    public var z: [Float]
    /// ARKit per-point confidence (0 = low, 2 = high) if the source provided it.
    public var confidence: [UInt8]?
    /// RGB if the source provided it (e.g. an `ARMeshAnchor` with vertex colors, or none).
    public var color: [SIMD3<UInt8>]?

    public var count: Int {
        x.count
    }

    public var isEmpty: Bool {
        x.isEmpty
    }

    public init(
        x: [Float] = [], y: [Float] = [], z: [Float] = [],
        confidence: [UInt8]? = nil, color: [SIMD3<UInt8>]? = nil
    ) {
        precondition(y.count == x.count && z.count == x.count, "x/y/z must have equal counts")
        precondition(confidence == nil || confidence?.count == x.count, "confidence count must match points")
        precondition(color == nil || color?.count == x.count, "color count must match points")
        self.x = x
        self.y = y
        self.z = z
        self.confidence = confidence
        self.color = color
    }

    public static let empty = PointCloud()

    public func point(at i: Int) -> SIMD3<Float> {
        SIMD3(x[i], y[i], z[i])
    }

    /// Appends another cloud's points. If exactly one side has confidence/color, the other
    /// side's missing values are backfilled (confidence 0 = "unknown", color black) rather than
    /// silently dropping the column — losing per-point provenance by surprise is worse than an
    /// explicit placeholder value.
    public mutating func append(_ other: PointCloud) {
        guard !other.isEmpty else { return }
        let selfCount = count
        x.append(contentsOf: other.x)
        y.append(contentsOf: other.y)
        z.append(contentsOf: other.z)

        if confidence != nil || other.confidence != nil {
            var merged = confidence ?? [UInt8](repeating: 0, count: selfCount)
            merged.append(contentsOf: other.confidence ?? [UInt8](repeating: 0, count: other.count))
            confidence = merged
        }
        if color != nil || other.color != nil {
            var merged = color ?? [SIMD3<UInt8>](repeating: .zero, count: selfCount)
            merged.append(contentsOf: other.color ?? [SIMD3<UInt8>](repeating: .zero, count: other.count))
            color = merged
        }
    }
}
