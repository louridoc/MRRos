@testable import LiDARScan
import simd
import Testing

struct SceneFilterTests {
    private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    private let unitBox = OrientedBox(
        boxFromWorld: matrix_identity_float4x4,
        min: SIMD3(-1, -1, -1),
        max: SIMD3(1, 1, 1)
    )

    @Test func containsIsInclusiveAndRespectsPadding() {
        #expect(unitBox.contains(SIMD3(0, 0, 0)))
        #expect(unitBox.contains(SIMD3(1, 1, 1)))
        #expect(!unitBox.contains(SIMD3(1.05, 0, 0)))
        #expect(unitBox.contains(SIMD3(1.05, 0, 0), padding: 0.1))
    }

    @Test func worldPlacementIsApplied() {
        // A box whose world pose is "translated +5 on X": its local origin is world (5, 0, 0).
        let box = OrientedBox(
            worldFromBox: translation(SIMD3(5, 0, 0)),
            min: SIMD3(-1, -1, -1),
            max: SIMD3(1, 1, 1)
        )
        #expect(box.contains(SIMD3(5.5, 0, 0)))
        #expect(!box.contains(SIMD3(0, 0, 0)))
    }

    @Test func rotationIsApplied() {
        // Long along local X (±2), thin elsewhere (±0.1); rotated 90° about world Z → long along world Y.
        var rot = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        rot.columns.3 = SIMD4(0, 0, 0, 1)
        let box = OrientedBox(worldFromBox: rot, min: SIMD3(-2, -0.1, -0.1), max: SIMD3(2, 0.1, 0.1))
        #expect(box.contains(SIMD3(0, 1.5, 0)))
        #expect(!box.contains(SIMD3(1.5, 0, 0)))
    }

    @Test func classifiesRobotBeforeCrop() {
        // Point 0: inside a robot box (and the crop) → robot. Point 1: inside crop only → kept.
        // Point 2: outside crop → outsideCrop.
        let cloud = PointCloud(x: [0, 3, 50], y: [0, 0, 0], z: [0, 0, 0])
        let robot = OrientedBox(
            boxFromWorld: matrix_identity_float4x4,
            min: SIMD3(-0.5, -0.5, -0.5),
            max: SIMD3(0.5, 0.5, 0.5)
        )
        let crop = OrientedBox(
            boxFromWorld: matrix_identity_float4x4,
            min: SIMD3(-10, -10, -10),
            max: SIMD3(10, 10, 10)
        )
        let classes = SceneFilter.classify(cloud, crop: crop, robot: [robot], robotPadding: 0)
        #expect(classes == [.robot, .kept, .outsideCrop])
    }

    @Test func noCropAndNoRobotKeepsEverything() {
        let cloud = PointCloud(x: [0, 100], y: [0, 0], z: [0, 0])
        #expect(SceneFilter.classify(cloud, crop: nil, robot: [], robotPadding: 0.05) == [.kept, .kept])
    }

    @Test func robotPaddingGrowsTheRemovedRegion() {
        let cloud = PointCloud(x: [0.52], y: [0], z: [0])
        let robot = OrientedBox(
            boxFromWorld: matrix_identity_float4x4,
            min: SIMD3(-0.5, -0.5, -0.5),
            max: SIMD3(0.5, 0.5, 0.5)
        )
        #expect(SceneFilter.classify(cloud, crop: nil, robot: [robot], robotPadding: 0) == [.kept])
        #expect(SceneFilter.classify(cloud, crop: nil, robot: [robot], robotPadding: 0.03) == [.robot])
    }

    @Test func selectingKeepsColumnsAligned() {
        let cloud = PointCloud(
            x: [1, 2, 3], y: [4, 5, 6], z: [7, 8, 9], confidence: [10, 20, 30],
            color: [SIMD3(1, 1, 1), SIMD3(2, 2, 2), SIMD3(3, 3, 3)]
        )
        let kept = cloud.selecting([.kept, .robot, .kept], equalTo: .kept)
        #expect(kept.x == [1, 3])
        #expect(kept.y == [4, 6])
        #expect(kept.z == [7, 9])
        #expect(kept.confidence == [10, 30])
        #expect(kept.color == [SIMD3(1, 1, 1), SIMD3(3, 3, 3)])
    }
}
