import LiDARScan
import RealityKit
import UIKit

/// The scan drawn in AR before upload: one mesh per `PointClass` (green = uploaded, red = robot,
/// grey = outside the crop box), each point a tiny tetrahedron — RealityKit has no point
/// primitive. Display-only: drawing is capped per class for frame rate, the upload is not.
@MainActor
final class ScanPreview {
    let root = Entity()
    private var parts: [Entity] = []

    private static let maxDrawnPerClass = 40000
    private static let size: Float = 0.008

    init() {
        root.name = "scan-preview"
    }

    /// `cloud` in AR world coordinates, `classes` index-aligned with it.
    func show(_ cloud: PointCloud, classes: [PointClass]) {
        clear()
        let styles: [(PointClass, UIColor)] = [
            (.kept, .systemGreen), (.robot, .systemRed), (.outsideCrop, UIColor(white: 0.6, alpha: 1)),
        ]
        for (cls, color) in styles {
            let points = cloud.selecting(classes, equalTo: cls)
            guard !points.isEmpty, let mesh = Self.mesh(points) else { continue }
            let part = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
            root.addChild(part)
            parts.append(part)
        }
    }

    func clear() {
        parts.forEach { $0.removeFromParent() }
        parts = []
    }

    private static func mesh(_ cloud: PointCloud) -> MeshResource? {
        let stride = max(1, cloud.count / maxDrawnPerClass)
        let s = size
        // Regular-ish tetrahedron around each point: visible from any angle with 4 triangles.
        let corners: [SIMD3<Float>] = [SIMD3(s, s, s), SIMD3(-s, -s, s), SIMD3(-s, s, -s), SIMD3(s, -s, -s)]
        let faces: [UInt32] = [0, 1, 2, 0, 3, 1, 0, 2, 3, 1, 3, 2]
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(cloud.count / stride * 4)
        indices.reserveCapacity(cloud.count / stride * 12)
        for i in Swift.stride(from: 0, to: cloud.count, by: stride) {
            let base = UInt32(positions.count)
            let p = cloud.point(at: i)
            positions.append(contentsOf: corners.map { p + $0 })
            indices.append(contentsOf: faces.map { base + $0 })
        }
        var descriptor = MeshDescriptor(name: "scan-points")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}
