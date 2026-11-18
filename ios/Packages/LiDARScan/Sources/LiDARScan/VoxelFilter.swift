import Foundation

/// Downsamples a point cloud for upload: a standard voxel-grid filter — bucket points into
/// `voxelSize`-sided cubes, replace each bucket with the mean of its points (position,
/// confidence, color independently). Point order is not preserved (buckets are unordered);
/// nothing downstream (PLY encoding, ar_bridge, RViz) depends on order.
public enum VoxelFilter {
    public static func downsample(_ cloud: PointCloud, voxelSize: Float) -> PointCloud {
        precondition(voxelSize > 0, "voxelSize must be positive")
        guard !cloud.isEmpty else { return cloud }

        struct Accumulator {
            var sumX: Double = 0, sumY: Double = 0, sumZ: Double = 0
            var sumConfidence: Double = 0
            var sumR: Double = 0, sumG: Double = 0, sumB: Double = 0
            var n: Int = 0
        }

        var buckets: [SIMD3<Int32>: Accumulator] = [:]
        buckets.reserveCapacity(cloud.count / 4) // real scans cluster heavily; a rough guess is fine

        for i in 0 ..< cloud.count {
            let key = SIMD3<Int32>(
                Int32((cloud.x[i] / voxelSize).rounded(.down)),
                Int32((cloud.y[i] / voxelSize).rounded(.down)),
                Int32((cloud.z[i] / voxelSize).rounded(.down))
            )
            var acc = buckets[key] ?? Accumulator()
            acc.sumX += Double(cloud.x[i])
            acc.sumY += Double(cloud.y[i])
            acc.sumZ += Double(cloud.z[i])
            if let c = cloud.confidence?[i] {
                acc.sumConfidence += Double(c)
            }
            if let col = cloud.color?[i] {
                acc.sumR += Double(col.x)
                acc.sumG += Double(col.y)
                acc.sumB += Double(col.z)
            }
            acc.n += 1
            buckets[key] = acc
        }

        var out = PointCloud(
            x: [], y: [], z: [],
            confidence: cloud.confidence != nil ? [] : nil,
            color: cloud.color != nil ? [] : nil
        )
        out.x.reserveCapacity(buckets.count)
        out.y.reserveCapacity(buckets.count)
        out.z.reserveCapacity(buckets.count)
        for acc in buckets.values {
            let n = Double(acc.n)
            out.x.append(Float(acc.sumX / n))
            out.y.append(Float(acc.sumY / n))
            out.z.append(Float(acc.sumZ / n))
            if cloud.confidence != nil {
                out.confidence!.append(UInt8((acc.sumConfidence / n).rounded()))
            }
            if cloud.color != nil {
                out.color!.append(SIMD3(
                    UInt8((acc.sumR / n).rounded()), UInt8((acc.sumG / n).rounded()),
                    UInt8((acc.sumB / n).rounded())
                ))
            }
        }
        return out
    }
}
