@testable import LiDARScan
import simd
import Testing

struct VoxelAccumulatorTests {
    private func sorted(_ c: PointCloud) -> [SIMD3<Float>] {
        (0 ..< c.count).map { c.point(at: $0) }.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
    }

    private let batch = PointCloud(
        x: [0.001, 0.009, 0.5, 0.51, -0.3], y: [0, 0, 0.5, 0.5, 0.2], z: [0, 0.001, 0, 0, -0.1],
        confidence: [2, 0, 1, 1, 2]
    )

    @Test func oneBatchMatchesVoxelFilter() {
        var acc = VoxelAccumulator(voxelSize: 0.02)
        acc.add(batch)
        let viaFilter = VoxelFilter.downsample(batch, voxelSize: 0.02)
        #expect(acc.count == viaFilter.count)
        let a = sorted(acc.cloud()), b = sorted(viaFilter)
        for (p, q) in zip(a, b) {
            #expect(simd_length(p - q) < 1e-6)
        }
    }

    @Test func recapturingTheSameSurfaceDoesNotGrowTheScan() {
        var acc = VoxelAccumulator(voxelSize: 0.02)
        acc.add(batch)
        let once = acc.count
        acc.add(batch)
        acc.add(batch)
        #expect(acc.count == once)
    }

    @Test func newSurfacesAddCells() {
        var acc = VoxelAccumulator(voxelSize: 0.02)
        acc.add(batch)
        acc.add(PointCloud(x: [5], y: [5], z: [5]))
        #expect(acc.count == VoxelFilter.downsample(batch, voxelSize: 0.02).count + 1)
    }

    @Test func averagesWithinACellAcrossCaptures() {
        var acc = VoxelAccumulator(voxelSize: 1)
        acc.add(PointCloud(x: [0.2], y: [0.2], z: [0.2]))
        acc.add(PointCloud(x: [0.4], y: [0.4], z: [0.4]))
        #expect(simd_length(acc.cloud().point(at: 0) - SIMD3(0.3, 0.3, 0.3)) < 1e-6)
    }

    @Test func keepsConfidenceAndBackfillsCellsWithoutIt() {
        var acc = VoxelAccumulator(voxelSize: 1)
        acc.add(PointCloud(x: [0.5], y: [0.5], z: [0.5], confidence: [2]))
        acc.add(PointCloud(x: [5.5], y: [0.5], z: [0.5])) // no confidence column
        let c = acc.cloud()
        #expect(c.confidence?.sorted() == [0, 2])
    }

    @Test func removeAllEmpties() {
        var acc = VoxelAccumulator(voxelSize: 0.02)
        acc.add(batch)
        acc.removeAll()
        #expect(acc.isEmpty)
        #expect(acc.cloud().isEmpty)
        #expect(acc.cloud().confidence == nil)
    }
}
