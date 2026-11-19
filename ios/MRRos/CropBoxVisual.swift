import AlignmentKit
import RealityKit
import UIKit

/// The scan crop box drawn in AR: a faint fill plus 12 edges, in `base_link` coordinates (ROS
/// axes, via the same `FrameConventions.rosToAR` rotation the robot and the triad use). A child of
/// the alignment root, so it moves with the robot alignment. Every piece is one shared unit cube,
/// scaled — editing only moves/scales entities, it never rebuilds meshes.
@MainActor
final class CropBoxVisual {
    let root = Entity()
    private let fill: ModelEntity
    private var edges: [ModelEntity] = []

    private static let edgeThickness: Float = 0.008

    init() {
        root.name = "crop-box"
        let rosFrame = Entity()
        rosFrame.transform = Transform(matrix: FrameConventions.rosToARFloat)
        root.addChild(rosFrame)

        let cube = MeshResource.generateBox(size: 1)
        var fillMaterial = UnlitMaterial(color: .systemYellow)
        fillMaterial.blending = .transparent(opacity: 0.08)
        fill = ModelEntity(mesh: cube, materials: [fillMaterial])
        rosFrame.addChild(fill)
        for _ in 0 ..< 12 {
            let edge = ModelEntity(mesh: cube, materials: [UnlitMaterial(color: .systemYellow)])
            rosFrame.addChild(edge)
            edges.append(edge)
        }
        root.isEnabled = false
    }

    /// `center` and `half` (half-extents) in base_link, metres.
    func update(center: SIMD3<Float>, half: SIMD3<Float>) {
        fill.position = center
        fill.scale = half * 2
        var i = 0
        for axis in 0 ..< 3 {
            let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
            for a: Float in [-1, 1] {
                for b: Float in [-1, 1] {
                    var position = center
                    position[u] += a * half[u]
                    position[v] += b * half[v]
                    var scale = SIMD3<Float>(repeating: Self.edgeThickness)
                    scale[axis] = half[axis] * 2
                    edges[i].position = position
                    edges[i].scale = scale
                    i += 1
                }
            }
        }
    }
}
