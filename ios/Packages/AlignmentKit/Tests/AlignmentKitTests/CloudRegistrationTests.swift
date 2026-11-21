@testable import AlignmentKit
import LiDARScan
import simd
import Testing

struct CloudRegistrationTests {
    @Test func rotatedToROSAxesMatchesFrameConventionsPerPoint() {
        let cloud = PointCloud(x: [1, 0], y: [0, 1], z: [0, 0])
        let rotated = CloudRegistration.rotatedToROSAxes(cloud)
        for i in 0 ..< cloud.count {
            let expected = FrameConventions.toROS(point: cloud.point(at: i))
            #expect(rotated.point(at: i) == expected)
        }
    }

    @Test func rotatedToROSAxesPreservesConfidenceAndColor() {
        let cloud = PointCloud(
            x: [1], y: [2], z: [3], confidence: [7], color: [SIMD3(10, 20, 30)]
        )
        let rotated = CloudRegistration.rotatedToROSAxes(cloud)
        #expect(rotated.confidence == [7])
        #expect(rotated.color == [SIMD3(10, 20, 30)])
    }

    @Test func rotatedToROSAxesOnEmptyCloudStaysEmpty() {
        #expect(CloudRegistration.rotatedToROSAxes(.empty).isEmpty)
    }

    @Test func registeringAgainstIdentityAlignmentEqualsPlainRotation() {
        let cloud = PointCloud(x: [1, -2], y: [0.5, 3], z: [4, -1])
        let registered = CloudRegistration.registering(cloud, against: AlignmentTransform())
        let rotated = CloudRegistration.rotatedToROSAxes(cloud)
        #expect(registered == rotated)
    }

    @Test func registeringPlacesTheAlignmentOriginAtTheROSOrigin() {
        let anchorPosition = SIMD3<Float>(2, 0, 3)
        let alignment = AlignmentTransform(position: anchorPosition, yaw: 0.7)
        let cloud = PointCloud(x: [anchorPosition.x], y: [anchorPosition.y], z: [anchorPosition.z])
        let registered = CloudRegistration.registering(cloud, against: alignment)
        let p = registered.point(at: 0)
        #expect(simd_length(p) < 1e-5)
    }

    @Test func registeringTranslationOnlyMatchesSimpleSubtraction() {
        // With yaw = 0, registering should be exactly "subtract the anchor, then rotate axes" —
        // the same shape as M3's original translation-only stopgap, just generalized.
        let anchor = SIMD3<Float>(1, 0, 2)
        let alignment = AlignmentTransform(position: anchor, yaw: 0)
        let p = SIMD3<Float>(3, 1, 5)
        let cloud = PointCloud(x: [p.x], y: [p.y], z: [p.z])
        let registered = CloudRegistration.registering(cloud, against: alignment)
        let expected = FrameConventions.toROS(point: p - anchor)
        #expect(simd_length(registered.point(at: 0) - expected) < 1e-5)
    }

    @Test func registeringPreservesPointCount() {
        let cloud = PointCloud(x: [1, 2, 3], y: [0, 0, 0], z: [0, 0, 0])
        let registered = CloudRegistration.registering(
            cloud,
            against: AlignmentTransform(position: SIMD3(1, 1, 1))
        )
        #expect(registered.count == cloud.count)
    }

    @Test func toWorldUndoesRegistering() {
        let cloud = PointCloud(x: [0.3, -1.2, 2.0], y: [0.1, 0.5, -0.7], z: [-0.4, 1.1, 0.0])
        let alignment = AlignmentTransform(position: SIMD3(0.5, -0.2, -1.5), yaw: 0.9)
        let back = CloudRegistration.toWorld(
            CloudRegistration.registering(cloud, against: alignment), from: alignment
        )
        for i in 0 ..< cloud.count {
            #expect(simd_length(back.point(at: i) - cloud.point(at: i)) < 1e-5)
        }
    }
}
