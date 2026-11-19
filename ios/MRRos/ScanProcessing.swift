import ARKit
import LiDARScan
import simd

/// One ARMeshAnchor's raw vertices, copied out on the main thread (a single memcpy) so ARKit's
/// buffers aren't touched again and everything else can run off the main thread.
struct MeshChunk: Sendable {
    let vertices: Data // packed `stride` bytes per vertex, x/y/z as the first 3 Floats
    let stride: Int
    let count: Int
    let transform: simd_float4x4

    init?(_ anchor: ARMeshAnchor) {
        let source = anchor.geometry.vertices
        guard source.format == .float3, source.count > 0 else { return nil }
        let base = source.buffer.contents().advanced(by: source.offset)
        vertices = Data(bytes: base, count: source.count * source.stride)
        stride = source.stride
        count = source.count
        transform = anchor.transform
    }

    /// Appends this chunk's vertices in AR world space. ARKit packs them as 3 floats (12 bytes);
    /// read exactly that, unaligned — never as SIMD3<Float> (16 bytes; see the M3 crash fix).
    func appendWorldPoints(x: inout [Float], y: inout [Float], z: inout [Float]) {
        vertices.withUnsafeBytes { raw in
            for i in 0 ..< count {
                let (vx, vy, vz) = raw.loadUnaligned(
                    fromByteOffset: i * stride,
                    as: (Float, Float, Float).self
                )
                let w = transform * SIMD4(vx, vy, vz, 1)
                x.append(w.x)
                y.append(w.y)
                z.append(w.z)
            }
        }
    }
}

/// Owns the accumulated scan and does the heavy per-capture work off the main thread; as an
/// actor it also serializes overlapping captures. `epoch` makes Clear race-free: Clear bumps the
/// coordinator's epoch, and the first call here carrying a newer one resets the grid first — no
/// separate "reset" message whose ordering against the next capture isn't guaranteed.
actor ScanProcessor {
    private var grid: VoxelAccumulator
    private var epoch = 0

    init(voxelSize: Float) {
        grid = VoxelAccumulator(voxelSize: voxelSize)
    }

    func add(_ chunks: [MeshChunk], epoch: Int) -> PointCloud {
        adopt(epoch)
        let total = chunks.reduce(0) { $0 + $1.count }
        var x = [Float](), y = [Float](), z = [Float]()
        x.reserveCapacity(total)
        y.reserveCapacity(total)
        z.reserveCapacity(total)
        for chunk in chunks {
            chunk.appendWorldPoints(x: &x, y: &y, z: &z)
        }
        grid.add(PointCloud(x: x, y: y, z: z, confidence: [UInt8](repeating: 2, count: x.count)))
        return grid.cloud()
    }

    /// Releases the grid's memory after a Clear even if no capture follows.
    func release(epoch: Int) {
        adopt(epoch)
    }

    private func adopt(_ newEpoch: Int) {
        if newEpoch > epoch {
            grid.removeAll()
            epoch = newEpoch
        }
    }
}

/// Everything the AR preview needs, computed off the main thread: per-point classes (also reused
/// by upload), counts, and ready-made geometry (positions + indices) per class.
struct PreviewGeometry: Sendable {
    struct Part: Sendable {
        let cls: PointClass
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
    }

    let classes: [PointClass]
    let parts: [Part]
    let kept: Int
    let robot: Int
    let excluded: Int
    let cropped: Int

    /// Drawing is capped per class — display only, the upload always uses every point.
    static let maxDrawnPerClass = 25000
    private static let pointSize: Float = 0.008

    static func compute(
        _ cloud: PointCloud, crop: OrientedBox?, exclusions: [OrientedBox], robot: [OrientedBox],
        robotPadding: Float
    ) -> PreviewGeometry {
        let classes = SceneFilter.classify(
            cloud, crop: crop, exclusions: exclusions, robot: robot, robotPadding: robotPadding
        )
        var byClass: [PointClass: [Int]] = [:]
        for (i, c) in classes.enumerated() {
            byClass[c, default: []].append(i)
        }
        let s = pointSize
        // Small tetrahedron per point: visible from every angle with only 4 triangles.
        let corners: [SIMD3<Float>] = [SIMD3(s, s, s), SIMD3(-s, -s, s), SIMD3(-s, s, -s), SIMD3(s, -s, -s)]
        let faces: [UInt32] = [0, 1, 2, 0, 3, 1, 0, 2, 3, 1, 3, 2]
        let parts: [Part] = [PointClass.kept, .robot, .excluded, .outsideCrop].compactMap { cls in
            guard let idx = byClass[cls], !idx.isEmpty else { return nil }
            let stride = max(1, idx.count / maxDrawnPerClass)
            let drawn = Swift.stride(from: 0, to: idx.count, by: stride).map { idx[$0] }
            var positions = [SIMD3<Float>]()
            var indices = [UInt32]()
            positions.reserveCapacity(drawn.count * 4)
            indices.reserveCapacity(drawn.count * 12)
            for i in drawn {
                let base = UInt32(positions.count)
                let p = cloud.point(at: i)
                for c in corners {
                    positions.append(p + c)
                }
                for f in faces {
                    indices.append(base + f)
                }
            }
            return Part(cls: cls, positions: positions, indices: indices)
        }
        return PreviewGeometry(
            classes: classes, parts: parts,
            kept: byClass[.kept]?.count ?? 0, robot: byClass[.robot]?.count ?? 0,
            excluded: byClass[.excluded]?.count ?? 0,
            cropped: byClass[.outsideCrop]?.count ?? 0
        )
    }
}
