import Foundation
@testable import LiDARScan
import Testing

struct VoxelFilterTests {
    private func close(_ a: Float, _ b: Float, tol: Float = 1e-5) -> Bool {
        abs(a - b) < tol
    }

    @Test func emptyCloudStaysEmpty() {
        let out = VoxelFilter.downsample(.empty, voxelSize: 0.05)
        #expect(out.isEmpty)
    }

    @Test func pointsInTheSameVoxelAreAveraged() {
        let cloud = PointCloud(x: [0.01, 0.02, 0.03], y: [0, 0, 0], z: [0, 0, 0])
        let out = VoxelFilter.downsample(cloud, voxelSize: 1.0) // all three fall in voxel (0,0,0)
        #expect(out.count == 1)
        #expect(close(out.x[0], 0.02))
    }

    @Test func pointsInDifferentVoxelsStaySeparate() {
        let cloud = PointCloud(x: [0.1, 5.1], y: [0, 0], z: [0, 0])
        let out = VoxelFilter.downsample(cloud, voxelSize: 1.0)
        #expect(out.count == 2)
    }

    @Test func confidenceAndColorAreAveragedIndependently() {
        let cloud = PointCloud(
            x: [0, 0.01], y: [0, 0], z: [0, 0],
            confidence: [0, 2], color: [SIMD3(0, 0, 0), SIMD3(100, 100, 100)]
        )
        let out = VoxelFilter.downsample(cloud, voxelSize: 1.0)
        #expect(out.count == 1)
        #expect(out.confidence?[0] == 1) // mean of 0 and 2
        #expect(out.color?[0] == SIMD3<UInt8>(50, 50, 50))
    }

    @Test func outputHasNoConfidenceOrColorWhenInputHadNone() {
        let cloud = PointCloud(x: [0], y: [0], z: [0])
        let out = VoxelFilter.downsample(cloud, voxelSize: 1.0)
        #expect(out.confidence == nil)
        #expect(out.color == nil)
    }

    @Test func negativeCoordinatesBucketByFlooringNotTruncating() {
        // floor(-0.1) = -1, floor(0.1) = 0: a voxel grid spanning the origin must NOT merge
        // these via naive integer truncation (which would put both at "0" and merge them).
        let cloud = PointCloud(x: [-0.1, 0.1], y: [0, 0], z: [0, 0])
        let out = VoxelFilter.downsample(cloud, voxelSize: 1.0)
        #expect(out.count == 2)
    }

    @Test func reducesPointCountForADenseCluster() {
        var x: [Float] = [], y: [Float] = [], z: [Float] = []
        for i in 0 ..< 1000 {
            x.append(Float(i % 10) * 0.001) // all within one 0.05 voxel on x
            y.append(0)
            z.append(0)
        }
        let cloud = PointCloud(x: x, y: y, z: z)
        let out = VoxelFilter.downsample(cloud, voxelSize: 0.05)
        #expect(out.count == 1)
    }
}

struct PointCloudTests {
    @Test func appendConcatenatesParallelArrays() {
        var a = PointCloud(x: [1], y: [2], z: [3])
        let b = PointCloud(x: [4], y: [5], z: [6])
        a.append(b)
        #expect(a.x == [1, 4])
        #expect(a.count == 2)
    }

    @Test func appendBackfillsMissingConfidenceAndColorRatherThanDroppingThem() {
        var a = PointCloud(x: [1], y: [1], z: [1], confidence: [9])
        let b = PointCloud(x: [2], y: [2], z: [2]) // no confidence at all
        a.append(b)
        #expect(a.confidence == [9, 0], "b's missing confidence is backfilled as 0, not dropped")
    }

    @Test func emptyAppendIsANoOp() {
        var a = PointCloud(x: [1], y: [1], z: [1])
        a.append(.empty)
        #expect(a.count == 1)
    }

    @Test func pointAtReturnsTheRightComponents() {
        let a = PointCloud(x: [1, 2], y: [3, 4], z: [5, 6])
        #expect(a.point(at: 1) == SIMD3<Float>(2, 4, 6))
    }
}
