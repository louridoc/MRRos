import Foundation
import simd

/// A triangle mesh of the scanned room (ARKit's reconstruction), in whatever frame its vertices
/// are in. The mesh counterpart of `PointCloud` for the M5c mesh upload.
public struct ScanMesh: Sendable, Equatable {
    public var vertices: [SIMD3<Float>]
    /// Flat vertex indices, three per triangle.
    public var indices: [UInt32]

    public init(vertices: [SIMD3<Float>] = [], indices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
    }

    public static let empty = ScanMesh()

    public var triangleCount: Int {
        indices.count / 3
    }

    public var isEmpty: Bool {
        triangleCount == 0
    }

    /// One point per triangle (its centroid) — what the scan filter classifies, so a triangle is
    /// kept or dropped as a whole, by where its middle is.
    public func centroids() -> PointCloud {
        var x = [Float](), y = [Float](), z = [Float]()
        x.reserveCapacity(triangleCount)
        y.reserveCapacity(triangleCount)
        z.reserveCapacity(triangleCount)
        for t in 0 ..< triangleCount {
            let c = (vertices[Int(indices[3 * t])] + vertices[Int(indices[3 * t + 1])]
                + vertices[Int(indices[3 * t + 2])]) / 3
            x.append(c.x)
            y.append(c.y)
            z.append(c.z)
        }
        return PointCloud(x: x, y: y, z: z)
    }

    /// The triangles with `keep[t]` true; vertices no kept triangle uses are dropped.
    public func keepingTriangles(_ keep: [Bool]) -> ScanMesh {
        precondition(keep.count == triangleCount, "one flag per triangle")
        var remap = [Int32](repeating: -1, count: vertices.count)
        var outVertices = [SIMD3<Float>]()
        var outIndices = [UInt32]()
        outIndices.reserveCapacity(indices.count)
        for t in 0 ..< triangleCount where keep[t] {
            for k in 0 ..< 3 {
                let old = Int(indices[3 * t + k])
                if remap[old] < 0 {
                    remap[old] = Int32(outVertices.count)
                    outVertices.append(vertices[old])
                }
                outIndices.append(UInt32(remap[old]))
            }
        }
        return ScanMesh(vertices: outVertices, indices: outIndices)
    }

    /// Same triangles, every vertex transformed (e.g. AR world → base_link).
    public func mappingVertices(_ transform: (SIMD3<Float>) -> SIMD3<Float>) -> ScanMesh {
        ScanMesh(vertices: vertices.map(transform), indices: indices)
    }

    public mutating func append(_ other: ScanMesh) {
        let offset = UInt32(vertices.count)
        vertices += other.vertices
        indices += other.indices.map { $0 + offset }
    }
}

public enum MeshPLYError: Error, Equatable, Sendable {
    case malformed(String)
}

/// Binary little-endian PLY with triangles — the `POST /v0/scene_mesh` body. Mirrors
/// `ar_bridge/mesh_ply.py`; change both together (docs/protocols/ar_bridge_http.md).
public enum MeshPLY {
    public static func encode(_ mesh: ScanMesh) -> Data {
        let header = "ply\nformat binary_little_endian 1.0\ncomment MRRos scan mesh\n"
            + "element vertex \(mesh.vertices.count)\nproperty float x\nproperty float y\nproperty float z\n"
            + "element face \(mesh.triangleCount)\nproperty list uchar uint vertex_indices\nend_header\n"
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + mesh.vertices.count * 12 + mesh.triangleCount * 13)
        for v in mesh.vertices {
            for f in [v.x, v.y, v.z] {
                withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        for t in 0 ..< mesh.triangleCount {
            data.append(3)
            for k in 0 ..< 3 {
                withUnsafeBytes(of: mesh.indices[3 * t + k].littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ScanMesh {
        let marker = Data("end_header\n".utf8)
        guard let end = data.range(of: marker) else { throw MeshPLYError.malformed("missing end_header") }
        let header = String(decoding: data[data.startIndex ..< end.lowerBound], as: UTF8.self)
        var counts: [String: Int] = [:]
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "element", let n = Int(parts[2]) {
                counts[String(parts[1])] = n
            }
        }
        guard header.hasPrefix("ply\nformat binary_little_endian 1.0\n"),
              header.contains("property list uchar uint vertex_indices"),
              let n = counts["vertex"], let m = counts["face"]
        else { throw MeshPLYError.malformed("not an MRRos mesh PLY") }
        let body = data[end.upperBound...]
        guard body.count >= n * 12 + m * 13 else { throw MeshPLYError.malformed("truncated") }

        return body.withUnsafeBytes { raw -> ScanMesh in
            var vertices = [SIMD3<Float>]()
            vertices.reserveCapacity(n)
            for i in 0 ..< n {
                func f(_ k: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                        fromByteOffset: i * 12 + k * 4,
                        as: UInt32.self
                    )))
                }
                vertices.append(SIMD3(f(0), f(1), f(2)))
            }
            var indices = [UInt32]()
            indices.reserveCapacity(m * 3)
            for t in 0 ..< m {
                let base = n * 12 + t * 13 + 1
                for k in 0 ..< 3 {
                    indices.append(UInt32(littleEndian: raw.loadUnaligned(
                        fromByteOffset: base + k * 4,
                        as: UInt32.self
                    )))
                }
            }
            return ScanMesh(vertices: vertices, indices: indices)
        }
    }
}
