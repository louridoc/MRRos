import AlignmentKit
import RealityKit
import UIKit

/// A `BaseLinkBox` drawn in AR: a faint fill plus 12 edges, in base_link coordinates (ROS axes via
/// `FrameConventions.rosToAR`, the same rotation the robot and the triad use). A child of the
/// alignment root, so it moves with the robot. Used for the crop box (yellow) and the exclusion
/// boxes (orange). Every piece is one shared unit cube, scaled — editing only moves/scales
/// entities, it never rebuilds meshes.
@MainActor
final class BoxVisual {
    let root = Entity()
    private let boxFrame = Entity()
    private let fill: ModelEntity
    private var edges: [ModelEntity] = []

    private static let edgeThickness: Float = 0.008

    init(color: UIColor, fillOpacity: Float) {
        let rosFrame = Entity()
        rosFrame.transform = Transform(matrix: FrameConventions.rosToARFloat)
        root.addChild(rosFrame)
        rosFrame.addChild(boxFrame)

        let cube = MeshResource.generateBox(size: 1)
        var fillMaterial = UnlitMaterial(color: color)
        fillMaterial.blending = .transparent(opacity: .init(floatLiteral: fillOpacity))
        fill = ModelEntity(mesh: cube, materials: [fillMaterial])
        boxFrame.addChild(fill)
        for _ in 0 ..< 12 {
            let edge = ModelEntity(mesh: cube, materials: [UnlitMaterial(color: color)])
            boxFrame.addChild(edge)
            edges.append(edge)
        }
    }

    func update(_ box: BaseLinkBox) {
        boxFrame.transform = Transform(matrix: box.baseLinkFromBox)
        let half = box.half
        fill.scale = half * 2
        var i = 0
        for axis in 0 ..< 3 {
            let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
            for a: Float in [-1, 1] {
                for b: Float in [-1, 1] {
                    var position = SIMD3<Float>.zero
                    position[u] = a * half[u]
                    position[v] = b * half[v]
                    var scale = SIMD3<Float>(repeating: Self.edgeThickness)
                    scale[axis] = half[axis] * 2
                    edges[i].position = position
                    edges[i].scale = scale
                    i += 1
                }
            }
        }
    }

    /// The box being edited reads solid; the others dim, so it's clear which one a drag moves.
    func setSelected(_ selected: Bool) {
        for edge in edges {
            edge.components.set(OpacityComponent(opacity: selected ? 1 : 0.4))
        }
    }
}
