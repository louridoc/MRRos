import Foundation
@testable import LiDARScan
import simd
import Testing

struct ScanMeshTests {
    /// Two triangles sharing an edge, plus a far one.
    private let mesh = ScanMesh(
        vertices: [
            SIMD3(0, 0, 0),
            SIMD3(1, 0, 0),
            SIMD3(0, 1, 0),
            SIMD3(1, 1, 0),
            SIMD3(9, 9, 9),
            SIMD3(10, 9, 9),
            SIMD3(9, 10, 9),
        ],
        indices: [0, 1, 2, 1, 3, 2, 4, 5, 6]
    )

    @Test func plyRoundTripAnd13ByteFaces() throws {
        let data = MeshPLY.encode(mesh)
        #expect(try MeshPLY.decode(data) == mesh)
        let headerEnd = try #require(data.range(of: Data("end_header\n".utf8))).upperBound
        // 7 vertices x 12 bytes + 3 faces x 13 bytes. Kept out of #expect: older compilers
        // time out type-checking the literal arithmetic inside the macro.
        let bodyBytes: Int = data.count - headerEnd
        let expected: Int = 7 * 12 + 3 * 13
        #expect(bodyBytes == expected)
    }

    @Test func centroidsOnePerTriangle() {
        let c = mesh.centroids()
        #expect(c.count == 3)
        #expect(simd_length(c.point(at: 2) - SIMD3(28.0 / 3, 28.0 / 3, 9)) < 1e-5)
    }

    @Test func keepingTrianglesCompactsVertices() {
        let kept = mesh.keepingTriangles([false, true, true])
        #expect(kept.triangleCount == 2)
        #expect(kept.vertices.count == 6) // vertex 0 is no longer used
        #expect(kept.vertices[Int(kept.indices[0])] == SIMD3(1, 0, 0))
    }

    @Test func appendOffsetsIndices() {
        var a = ScanMesh(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 1, 2])
        a.append(a)
        #expect(a.indices == [0, 1, 2, 3, 4, 5])
    }

    @Test func malformedIsRejected() {
        #expect(throws: MeshPLYError.self) { try MeshPLY.decode(Data("nope".utf8)) }
        #expect(throws: MeshPLYError.self) { try MeshPLY.decode(MeshPLY.encode(mesh).dropLast(4)) }
    }

    /// Writes ar_bridge's cross-language mesh fixture (test/fixtures/mesh_v1.ply) when
    /// MRROS_SCENE_FIXTURE_DIR is set; Python must decode it to exactly this mesh.
    @Test func writeCrossLanguageMeshFixture() throws {
        guard let dir = ProcessInfo.processInfo.environment["MRROS_SCENE_FIXTURE_DIR"] else { return }
        try MeshPLY.encode(mesh).write(to: URL(fileURLWithPath: dir).appendingPathComponent("mesh_v1.ply"))
    }
}
