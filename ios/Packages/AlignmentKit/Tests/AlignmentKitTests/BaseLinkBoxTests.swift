@testable import AlignmentKit
import Foundation
import simd
import Testing

struct BaseLinkBoxTests {
    private let alignment = AlignmentTransform(position: SIMD3(0.5, 0.1, -1.5), yaw: 0.6)

    private func world(_ baseLinkPoint: SIMD3<Float>) -> SIMD3<Float> {
        alignment.worldPoint(fromBaseLink: baseLinkPoint)
    }

    @Test func containsItsCentreAndRespectsHalfExtentsInBaseLink() {
        let box = BaseLinkBox(center: SIMD3(1, 0, 0.5), half: SIMD3(0.2, 0.1, 0.3)).oriented(in: alignment)
        #expect(box.contains(world(SIMD3(1, 0, 0.5))))
        #expect(box.contains(world(SIMD3(1.19, 0.09, 0.79))))
        #expect(!box.contains(world(SIMD3(1.25, 0, 0.5))))
        #expect(!box.contains(world(SIMD3(1, 0, 0.85))))
    }

    @Test func yawRotatesTheBoxAboutBaseZ() {
        // Long along its own X (±0.5), thin in Y (±0.05); yawed 90° → long along base Y.
        let box = BaseLinkBox(center: .zero, half: SIMD3(0.5, 0.05, 0.05), yaw: .pi / 2).oriented(in: alignment)
        #expect(box.contains(world(SIMD3(0, 0.4, 0))))
        #expect(!box.contains(world(SIMD3(0.4, 0, 0))))
    }

    @Test func ownAxesFollowYaw() {
        let box = BaseLinkBox(center: .zero, half: SIMD3(repeating: 0.1), yaw: .pi / 2)
        #expect(simd_length(box.axisInBaseLink(0) - SIMD3(0, 1, 0)) < 1e-6)
        #expect(simd_length(box.axisInBaseLink(1) - SIMD3(-1, 0, 0)) < 1e-6)
        #expect(simd_length(box.axisInBaseLink(2) - SIMD3(0, 0, 1)) < 1e-6)
    }

    @Test func baseLinkPlacementAgreesWithWorldPlacement() {
        let box = BaseLinkBox(center: SIMD3(0.4, -0.2, 0.3), half: SIMD3(0.1, 0.2, 0.05), yaw: 0.7)
        for p: SIMD3<Float> in [SIMD3(0.4, -0.2, 0.3), SIMD3(0.5, -0.05, 0.32), SIMD3(0.7, -0.2, 0.3)] {
            #expect(box.orientedInBaseLink.contains(p) == box.oriented(in: alignment).contains(world(p)))
        }
    }

    @Test func codableRoundTrip() throws {
        let box = BaseLinkBox(center: SIMD3(1, 2, 3), half: SIMD3(0.1, 0.2, 0.3), yaw: -0.4)
        let decoded = try JSONDecoder().decode(BaseLinkBox.self, from: JSONEncoder().encode(box))
        #expect(decoded == box)
    }
}
