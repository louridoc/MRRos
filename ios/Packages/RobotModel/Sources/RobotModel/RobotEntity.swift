#if canImport(RealityKit) && os(iOS)
    import AlignmentKit
    import Foundation
    import MeshProvider
    import os
    import RealityKit
    import simd
    import UIKit
import URDFKit

    /// A URDF robot as a RealityKit entity tree.
    ///
    /// Layout: `root` (place this in the world) → `rosFrame` (carries the ROS→AR rotation, so
    /// everything below is in plain URDF/ROS coordinates) → one entity per link, positioned with
    /// the *absolute* link pose from `URDFRobot.linkTransforms`, → one entity per visual.
    @MainActor
    public final class RobotEntity {
        public let robot: URDFRobot
        public let root: Entity
        public private(set) var linkEntities: [String: Entity] = [:]
        /// Visual mesh URIs that could not be loaded and got a placeholder instead.
        public private(set) var placeholders: [String] = []

        private let rosFrame: Entity
        private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "RobotModel")

        /// Builds the tree and loads meshes (bundled → cache). Never throws for a missing mesh: the
        /// visual gets a placeholder built from the collision geometry (or a small box).
        public init(robot: URDFRobot, meshes: MeshProvider) async {
            self.robot = robot
            root = Entity()
            root.name = "robot:\(robot.name)"
            rosFrame = Entity()
            rosFrame.name = "ros_frame"
            rosFrame.transform = Transform(matrix: FrameConventions.rosToARFloat)
            root.addChild(rosFrame)

            for linkName in robot.linkNamesInTreeOrder() {
                let linkEntity = Entity()
                linkEntity.name = "link:\(linkName)"
                rosFrame.addChild(linkEntity)
                linkEntities[linkName] = linkEntity
                guard let link = robot.links[linkName] else { continue }
                for (i, visual) in link.visuals.enumerated() {
                    let visualEntity = await makeVisual(
                        visual,
                        fallback: link.collisions.first,
                        meshes: meshes
                    )
                    visualEntity.name = "visual:\(linkName)#\(i)"
                    rosFrame.addChild(visualEntity) // re-parented below
                    linkEntity.addChild(visualEntity)
                }
            }
            update(jointPositions: [:])
        }

        /// Re-pose every link from the FK. Call on each joint update (or each frame when smoothing).
        public func update(jointPositions: [String: Double]) {
            let poses = robot.linkTransforms(jointPositions: jointPositions)
            for (name, entity) in linkEntities {
                if let m = poses[name] {
                    entity.transform = Transform(matrix: m.floatMatrix)
                }
            }
        }

        // MARK: - Visuals

        private func makeVisual(_ visual: Shape, fallback: Shape?, meshes: MeshProvider) async -> Entity {
            let holder = Entity()
            holder.transform = Transform(matrix: visual.origin.matrix.floatMatrix)
            switch visual.geometry {
            case let .mesh(filename, scale):
                do {
                    let url = try await meshes.resolve(filename)
                    let loaded = try await Entity(contentsOf: url)
                    loaded.scale = SIMD3<Float>(scale)
                    holder.addChild(loaded)
                } catch {
                    log
                        .warning(
                            "mesh \(filename, privacy: .public): \(String(describing: error), privacy: .public) → placeholder"
                        )
                    placeholders.append(filename)
                    holder.addChild(Self.placeholder(for: fallback ?? visual, tint: visual.material))
                }
            default:
                holder.addChild(Self.primitive(visual.geometry, material: visual.material))
            }
            return holder
        }

        /// Box/cylinder/sphere from URDF primitives. URDF cylinders are along Z; RealityKit's along Y.
        static func primitive(_ geometry: Geometry, material: URDFKit.Material?) -> ModelEntity {
            let mat = simpleMaterial(material)
            switch geometry {
            case let .box(size):
                return ModelEntity(mesh: .generateBox(size: SIMD3<Float>(size)), materials: [mat])
            case let .cylinder(radius, length):
                let e = ModelEntity(
                    mesh: .generateCylinder(height: Float(length), radius: Float(radius)),
                    materials: [mat]
                )
                e.transform.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
                return e
            case let .sphere(radius):
                return ModelEntity(mesh: .generateSphere(radius: Float(radius)), materials: [mat])
            case .mesh:
                return ModelEntity(mesh: .generateBox(size: 0.05), materials: [mat])
            }
        }

        static func placeholder(for shape: Shape, tint: URDFKit.Material?) -> Entity {
            let holder = Entity()
            holder.transform = Transform(matrix: shape.origin.matrix.floatMatrix)
            var mat = tint ?? shape.material
            if mat ==
                nil
            {
                mat = URDFKit.Material(name: "placeholder", rgba: SIMD4(0.9, 0.3, 0.1, 0.8), texture: nil)
            }
            let e = primitive(shape.geometry, material: mat)
            holder.addChild(e)
            return holder
        }

        static func simpleMaterial(_ material: URDFKit.Material?) -> SimpleMaterial {
            var m = SimpleMaterial()
            if let rgba = material?.rgba {
                m.color = .init(tint: UIColor(
                    red: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z),
                    alpha: CGFloat(rgba.w)
                ))
            } else {
                m.color = .init(tint: .lightGray)
            }
            m.roughness = 0.6
            m.metallic = 0.1
            return m
        }
    }
#endif
