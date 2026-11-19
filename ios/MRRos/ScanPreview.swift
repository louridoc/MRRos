import LiDARScan
import RealityKit
import UIKit

/// The scan drawn in AR before upload: one mesh per `PointClass` (green = uploaded, red = robot,
/// grey = outside the crop box). The geometry arrives precomputed (`PreviewGeometry`, built off
/// the main thread); this only turns it into RealityKit entities.
@MainActor
final class ScanPreview {
    let root = Entity()
    private var parts: [Entity] = []

    init() {
        root.name = "scan-preview"
    }

    func show(_ geometry: PreviewGeometry) async {
        var built: [Entity] = []
        for part in geometry.parts {
            var descriptor = MeshDescriptor(name: "scan-points")
            descriptor.positions = MeshBuffers.Positions(part.positions)
            descriptor.primitives = .triangles(part.indices)
            guard let mesh = try? await MeshResource(from: [descriptor]) else { continue }
            built.append(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: Self.color(part.cls))]))
        }
        // Swap only once everything is ready, so the old preview stays up meanwhile.
        clear()
        for entity in built {
            root.addChild(entity)
        }
        parts = built
    }

    func clear() {
        parts.forEach { $0.removeFromParent() }
        parts = []
    }

    private static func color(_ cls: PointClass) -> UIColor {
        switch cls {
        case .kept: .systemGreen
        case .robot: .systemRed
        case .excluded: .systemOrange
        case .outsideCrop: UIColor(white: 0.6, alpha: 1)
        }
    }
}
