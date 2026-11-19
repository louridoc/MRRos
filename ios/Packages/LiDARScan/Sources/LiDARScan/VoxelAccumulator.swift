import simd

/// A persistent voxel grid a scan is accumulated into, one capture at a time: each `add` only
/// touches the new points, instead of re-downsampling the whole growing cloud (what
/// `VoxelFilter.downsample(all + new)` per capture did — O(total) work and allocation per tap).
/// Each cell keeps running sums, so re-capturing the same surface just refines its average.
/// Same cell rule as `VoxelFilter`: `floor(coord / voxelSize)`.
public struct VoxelAccumulator: Sendable {
    public let voxelSize: Float

    private struct Cell {
        var sum = SIMD3<Double>.zero
        var n = 0
        var confidenceSum = 0.0
        var confidenceN = 0
        var colorSum = SIMD3<Double>.zero
        var colorN = 0
    }

    private var cells: [SIMD3<Int32>: Cell] = [:]
    private var sawConfidence = false
    private var sawColor = false

    public init(voxelSize: Float) {
        precondition(voxelSize > 0, "voxelSize must be positive")
        self.voxelSize = voxelSize
    }

    public var count: Int {
        cells.count
    }

    public var isEmpty: Bool {
        cells.isEmpty
    }

    public mutating func add(_ cloud: PointCloud) {
        sawConfidence = sawConfidence || cloud.confidence != nil
        sawColor = sawColor || cloud.color != nil
        cells.reserveCapacity(cells.count + cloud.count / 4)
        for i in 0 ..< cloud.count {
            let p = cloud.point(at: i)
            let key = SIMD3<Int32>((p / voxelSize).rounded(.down))
            var cell = cells[key] ?? Cell()
            cell.sum += SIMD3<Double>(p)
            cell.n += 1
            if let c = cloud.confidence?[i] {
                cell.confidenceSum += Double(c)
                cell.confidenceN += 1
            }
            if let c = cloud.color?[i] {
                cell.colorSum += SIMD3<Double>(c)
                cell.colorN += 1
            }
            cells[key] = cell
        }
    }

    public mutating func removeAll() {
        cells.removeAll(keepingCapacity: false)
        sawConfidence = false
        sawColor = false
    }

    /// One point per occupied cell (its average). Columns that some added cloud had are present;
    /// cells that never got a value for one report 0 / black, like `PointCloud.append`.
    public func cloud() -> PointCloud {
        var x = [Float](), y = [Float](), z = [Float]()
        x.reserveCapacity(cells.count)
        y.reserveCapacity(cells.count)
        z.reserveCapacity(cells.count)
        var confidence: [UInt8]? = sawConfidence ? [] : nil
        var color: [SIMD3<UInt8>]? = sawColor ? [] : nil
        for cell in cells.values {
            let mean = cell.sum / Double(cell.n)
            x.append(Float(mean.x))
            y.append(Float(mean.y))
            z.append(Float(mean.z))
            if sawConfidence {
                let v = cell.confidenceN > 0 ? cell.confidenceSum / Double(cell.confidenceN) : 0
                confidence?.append(UInt8(v.rounded()))
            }
            if sawColor {
                let v = cell.colorN > 0 ? cell.colorSum / Double(cell.colorN) : .zero
                color?.append(SIMD3<UInt8>(v.rounded(.toNearestOrAwayFromZero)))
            }
        }
        return PointCloud(x: x, y: y, z: z, confidence: confidence, color: color)
    }
}
