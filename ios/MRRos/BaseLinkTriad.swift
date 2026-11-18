import AlignmentKit
import RealityKit
import UIKit

/// Red/green/blue X/Y/Z arrows for `base_link`, drawn in ROS coordinates under an entity that
/// carries `FrameConventions.rosToAR` — the same rotation `RobotEntity` uses — so the arrows are
/// exactly the robot's axes (and the uploaded cloud's; see `AlignmentTransformTests`).
@MainActor
final class BaseLinkTriad {
    let root = Entity()
    private let arrows: [Entity] // X, Y, Z

    init() {
        root.name = "base_link-triad"
        let rosFrame = Entity()
        rosFrame.transform = Transform(matrix: FrameConventions.rosToARFloat)
        root.addChild(rosFrame)

        arrows = [
            Self.arrow(along: SIMD3(1, 0, 0), color: .systemRed),
            Self.arrow(along: SIMD3(0, 1, 0), color: .systemGreen),
            Self.arrow(along: SIMD3(0, 0, 1), color: .systemBlue),
        ]
        for arrow in arrows {
            rosFrame.addChild(arrow)
        }
        root.isEnabled = false
    }

    /// Full opacity on the arrow the drag acts on (Z for rotation, its axis), dim on the rest.
    func highlight(_ axis: RobotScene.AlignAxis) {
        let active = switch axis {
        case .x: 0
        case .y: 1
        case .yaw: 2
        }
        for (i, arrow) in arrows.enumerated() {
            arrow.components.set(OpacityComponent(opacity: i == active ? 1 : 0.3))
        }
    }

    /// Shaft + cone tip, built along +Y (RealityKit's primitive axis) and rotated onto `axis`.
    /// Longer than a CRX/UR base radius so the tips clear the robot body.
    private static func arrow(along axis: SIMD3<Float>, color: UIColor) -> Entity {
        let length: Float = 0.4
        let material = UnlitMaterial(color: color)
        let shaft = ModelEntity(mesh: .generateCylinder(height: length, radius: 0.008), materials: [material])
        shaft.position.y = length / 2
        let tip = ModelEntity(mesh: .generateCone(height: 0.06, radius: 0.022), materials: [material])
        tip.position.y = length + 0.03

        let arrow = Entity()
        arrow.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: axis)
        arrow.addChild(shaft)
        arrow.addChild(tip)
        return arrow
    }
}
