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

    @Test func baseLinkAxesAtZeroYawFollowFrameConventions() {
        let a = AlignmentTransform()
        #expect(close(a.worldVector(fromBaseLink: SIMD3(1, 0, 0)), SIMD3(1, 0, 0))) // X → AR X
        #expect(close(a.worldVector(fromBaseLink: SIMD3(0, 1, 0)), SIMD3(0, 0, -1))) // Y → AR −Z
        #expect(close(a.worldVector(fromBaseLink: SIMD3(0, 0, 1)), SIMD3(0, 1, 0))) // Z → AR up
    }

    @Test func baseLinkZStaysVerticalForAnyYaw() {
        for yaw: Float in [0, 0.7, -2.1, .pi] {
            let a = AlignmentTransform(yaw: yaw)
            #expect(close(a.worldVector(fromBaseLink: SIMD3(0, 0, 1)), SIMD3(0, 1, 0)))
        }
    }

    @Test func translatingAlongBaseXOrYNeverChangesHeight() {
        let a = AlignmentTransform(position: SIMD3(0.3, 0.12, -1), yaw: 1.3)
        #expect(abs(a.translatedInBaseLink(by: SIMD3(0.5, 0, 0)).position.y - 0.12) < 1e-6)
        #expect(abs(a.translatedInBaseLink(by: SIMD3(0, -0.4, 0)).position.y - 0.12) < 1e-6)
    }

    @Test func translatingAlongBaseZChangesOnlyHeightByExactlyTheDelta() {
        for yaw: Float in [0, 0.7, -2.1] {
            let a = AlignmentTransform(position: SIMD3(0.3, 0.12, -1), yaw: yaw)
            let moved = a.translatedInBaseLink(by: SIMD3(0, 0, 0.25))
            #expect(close(moved.position, SIMD3(0.3, 0.37, -1)))
            #expect(moved.yaw == yaw)
        }
    }

    /// The triad the user sees, the axis they drag along, and the frame the uploaded cloud is in
    /// must all be the same `base_link`: a point placed `v` along the drawn axes from the base
    /// must register (via the exact path `CloudRegistration` uses) as `v`.
    @Test func drawnBaseLinkAxesMatchTheRegistrationFrame() {
        let a = AlignmentTransform(position: SIMD3(0.4, 0, -2), yaw: 0.9)
        for v in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.3, -0.7, 0.2)] {
            let world = a.position + a.worldVector(fromBaseLink: v)
            let registered = FrameConventions.toROS(point: a.pointInBaseLink(world))
            #expect(close(registered, v))
        }
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

    @Test func worldFromBaseLinkAgreesWithWorldPointAndRegistration() {
        let a = AlignmentTransform(position: SIMD3(0.4, 0.1, -2), yaw: -0.8)
        for v in [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0.3, -0.7, 1.2)] {
            let viaMatrix4 = a.worldFromBaseLink * SIMD4(v, 1)
            let viaMatrix = SIMD3(viaMatrix4.x, viaMatrix4.y, viaMatrix4.z)
            #expect(close(viaMatrix, a.worldPoint(fromBaseLink: v)))
            // and back through the registration path the uploaded cloud uses
            #expect(close(FrameConventions.toROS(point: a.pointInBaseLink(viaMatrix)), v))
        }
    }
}
