@testable import AlignmentKit
import simd
import Testing

struct AlignmentTransformTests {
    private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tol: Float = 1e-5) -> Bool {
        simd_length(a - b) < tol
    }

    @Test func identityAlignmentLeavesPointsUnchanged() {
        let a = AlignmentTransform()
        let p = SIMD3<Float>(1, 2, 3)
        #expect(close(a.pointInBaseLink(p), p))
    }

    @Test func translationOnlyShiftsPointsByTheOppositeOffset() {
        let a = AlignmentTransform(position: SIMD3(1, 0, 2), yaw: 0)
        let p = SIMD3<Float>(1, 0, 2) // exactly at the anchor
        #expect(close(a.pointInBaseLink(p), .zero))
    }

    @Test func theAnchorsOwnPositionAlwaysMapsToTheOrigin() {
        for yaw: Float in [0, 0.3, -1.1, Float.pi, 2.9] {
            let a = AlignmentTransform(position: SIMD3(0.4, -0.2, 1.7), yaw: yaw)
            #expect(close(a.pointInBaseLink(a.position), .zero))
        }
    }

    @Test func yawRotatesPointsAboutTheVerticalAxis() {
        let a = AlignmentTransform(position: .zero, yaw: .pi / 2)
        // A point on +X, viewed from a frame rotated +90° about Y, lands on what was +Z or -Z
        // depending on handedness — just check it moved off the X axis and kept its radius.
        let p = SIMD3<Float>(1, 0, 0)
        let result = a.pointInBaseLink(p)
        #expect(abs(result.x) < 1e-5)
        #expect(simd_length(result) - 1 < 1e-5)
    }

    @Test func translatedAndRotatedComposeWithTheirOwnDeltas() {
        let a = AlignmentTransform(position: SIMD3(1, 0, 0), yaw: 0.2)
        let moved = a.translated(by: SIMD3(0, 0, 1))
        #expect(close(moved.position, SIMD3(1, 0, 1)))
        #expect(moved.yaw == a.yaw)

        let rotated = a.rotated(byYaw: 0.5)
        #expect(rotated.position == a.position)
        #expect(abs(rotated.yaw - 0.7) < 1e-6)
    }

    @Test func pointInBaseLinkRoundTripsThroughTheForwardTransform() {
        let a = AlignmentTransform(position: SIMD3(0.5, 0.1, -0.3), yaw: 1.234)
        let p = SIMD3<Float>(2, 0.5, -1)
        let relative = a.pointInBaseLink(p)
        let back4 = a.transform * SIMD4(relative, 1)
        #expect(close(SIMD3(back4.x, back4.y, back4.z), p))
    }

    @Test func fromWorldTransformExtractsPositionExactly() {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(3, 1, -2, 1)
        let a = AlignmentTransform.from(worldTransform: t)
        #expect(close(a.position, SIMD3(3, 1, -2)))
    }

    @Test func fromWorldTransformIsSelfConsistentWithTransform() {
        // Seeding from a transform built the same way `.transform` builds one should round-trip:
        // the extracted yaw, fed back through `.transform`, gives the same rotation back.
        let yaw: Float = 0.9
        var seed = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        seed.columns.3 = SIMD4(1, 0, 1, 1)
        let a = AlignmentTransform.from(worldTransform: seed)
        #expect(close(a.position, SIMD3(1, 0, 1)))
        #expect(abs(a.yaw - yaw) < 1e-5)
    }
}
