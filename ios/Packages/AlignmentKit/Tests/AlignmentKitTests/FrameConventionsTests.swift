@testable import AlignmentKit
import simd
import Testing

struct FrameConventionsTests {
    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tol: Double = 1e-12) -> Bool {
        simd_length(a - b) < tol
    }

    @Test func axesMapAsDocumented() {
        #expect(close(FrameConventions.toAR(point: SIMD3(1, 0, 0)), SIMD3(1, 0, 0))) // X stays
        #expect(close(FrameConventions.toAR(point: SIMD3(0, 1, 0)), SIMD3(0, 0, -1))) // Y → −Z
        #expect(close(FrameConventions.toAR(point: SIMD3(0, 0, 1)), SIMD3(0, 1, 0))) // Z up → Y up
    }

    @Test func isAProperRotation() {
        let r = FrameConventions.rosToAR
        let m3 = simd_double3x3(
            SIMD3(r.columns.0.x, r.columns.0.y, r.columns.0.z),
            SIMD3(r.columns.1.x, r.columns.1.y, r.columns.1.z),
            SIMD3(r.columns.2.x, r.columns.2.y, r.columns.2.z)
        )
        #expect(abs(m3.determinant - 1) < 1e-12, "must preserve handedness")
        let rt = r * FrameConventions.arToROS
        #expect(simd_almost_equal_elements(rt, matrix_identity_double4x4, 1e-12))
    }

    @Test func floatPointConversionMatchesTheDoublePath() {
        let arPoint = SIMD3<Float>(0.3, -1.2, 2.5)
        let viaFloat = FrameConventions.toROS(point: arPoint)
        let viaDouble = FrameConventions.toROS(point: SIMD3<Double>(arPoint))
        #expect(simd_length(viaFloat - SIMD3<Float>(viaDouble)) < 1e-5)
    }

    @Test func roundTripsPointsAndTransforms() {
        let p = SIMD3<Double>(0.3, -1.2, 2.5)
        #expect(close(FrameConventions.toROS(point: FrameConventions.toAR(point: p)), p))

        var t = simd_double4x4(simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))))
        t.columns.3 = SIMD4(1, 2, 3, 1)
        let back = FrameConventions.toROS(transform: FrameConventions.toAR(transform: t))
        #expect(simd_almost_equal_elements(back, t, 1e-12))
    }

    @Test func transformConversionIsAConjugation() {
        // Applying a ROS transform to a ROS point, then converting, equals converting both first.
        var t = simd_double4x4(simd_quatd(angle: 1.1, axis: SIMD3(0, 0, 1)))
        t.columns.3 = SIMD4(0.5, 0, 0.2, 1)
        let p = SIMD3<Double>(1, 1, 0)
        let viaROS = t * SIMD4(p, 1)
        let lhs = FrameConventions.toAR(point: SIMD3(viaROS.x, viaROS.y, viaROS.z))
        let viaAR = FrameConventions.toAR(transform: t) * SIMD4(FrameConventions.toAR(point: p), 1)
        #expect(close(lhs, SIMD3(viaAR.x, viaAR.y, viaAR.z)))
    }

    @Test func zUpBecomesYUpForARobotBase() {
        // A link 0.5 m above the ROS floor must end up 0.5 m above the AR floor.
        var t = matrix_identity_double4x4
        t.columns.3 = SIMD4(0, 0, 0.5, 1)
        let ar = FrameConventions.toAR(transform: t)
        #expect(close(SIMD3(ar.columns.3.x, ar.columns.3.y, ar.columns.3.z), SIMD3(0, 0.5, 0)))
    }
}
