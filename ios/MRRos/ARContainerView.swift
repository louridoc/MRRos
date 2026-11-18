import AlignmentKit
import AppCore
import ARBridgeTransport
import ARKit
import Combine
import LiDARScan
import MeshProvider
import os
import RealityKit
import RobotModel
import ROSMessages
import SwiftUI
import UIKit
import URDFKit

/// RealityKit AR session with scene reconstruction, hosting the robot entity.
struct ARContainerView: UIViewRepresentable {
    let session: ROSSession
    let scene: RobotScene
    let scanScene: ScanScene

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        view.environment.sceneUnderstanding.options = [.occlusion]
        view.debugOptions = [.showWorldOrigin]
        view.session.run(config)
        context.coordinator.attach(view)

        // Alignment gizmo: a single plain pan drag, whose horizontal screen delta moves the
        // robot along whichever axis `scene.alignAxis` currently selects (X / Z / yaw) — not a
        // free 2D/3D gesture. A no-op unless `scene.isAligning` is on — see `handlePan` — so it
        // doesn't interfere with normal AR viewing.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan)
        )
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.handleRequest()
        context.coordinator.handleScanRequest()
        context.coordinator.syncAligningState()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, scene: scene, scanScene: scanScene)
    }

    /// Owns the robot entity and drives it from `/joint_states` on every rendered frame.
    /// `NSObject` because `UIGestureRecognizer` targets need Objective-C dispatch.
    @MainActor
    final class Coordinator: NSObject {
        private let session: ROSSession
        private let scene: RobotScene
        private let scanScene: ScanScene
        private weak var arView: ARView?
        private var anchor: AnchorEntity?
        /// Visual gizmo (disc + heading arrow) shown at the anchor while aligning, so there's
        /// something on screen to look at besides the robot itself — a child of `anchor`, so it
        /// tracks position/yaw automatically.
        private var gizmo: Entity?
        /// Where `base_link` is in AR world space — seeded from the placement raycast, then
        /// refined live by the gizmo gestures while `scene.isAligning`. Scan uploads register
        /// against this, recomputed fresh at upload time (see `uploadScan`).
        private var alignment: AlignmentTransform?
        private var wasAligning = false
        private var robot: RobotEntity?
        private var mapper: JointStateMapper?
        private var smoother = JointSmoother(tau: 0.06)
        private var lastStamp: ROSTime?
        private var updateSubscription: Cancellable?
        private var buildTask: Task<Void, Never>?
        private var uploadTask: Task<Void, Never>?
        private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ARContainer")

        /// Accumulated across `.capture` requests in raw AR-world coordinates — neither the ROS
        /// axis rotation nor the robot-alignment registration is applied until upload time (see
        /// `captureScan`/`uploadScan`). Re-voxelized after every capture so repeated taps don't
        /// make the cloud grow without bound from re-scanning the same surfaces.
        private var scanCloud = PointCloud.empty
        private let scanVoxelSize: Float = 0.02

        /// Built fresh per placement from the session's CURRENT host, so a reconnect to a
        /// different lab PC (or ar_bridge simply coming up after rosbridge) is picked up without
        /// restarting the app. Bundled/cache tiers work even before any connection; the remote
        /// tier (M2b) is appended only when `arBridgeURL` resolves (host non-empty, valid port).
        private var meshes: MeshProvider {
            guard let arBridgeURL = session.settings.arBridgeURL else { return .standard() }
            return .standard(arBridge: ARBridgeClient(baseURL: arBridgeURL))
        }

        init(session: ROSSession, scene: RobotScene, scanScene: ScanScene) {
            self.session = session
            self.scene = scene
            self.scanScene = scanScene
            super.init()
        }

        func attach(_ view: ARView) {
            arView = view
            updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.tick(dt: event.deltaTime)
            }
        }

        func handleRequest() {
            guard let request = scene.request else { return }
            scene.request = nil
            switch request {
            case .place: place()
            case .remove: remove()
            }
        }

        // MARK: Placement

        private func place() {
            guard let arView else { return }
            guard let urdf = session.urdfRobot else {
                scene.status = "No robot description yet — connect first."
                return
            }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .horizontal)
                .first
            else {
                scene.status = "Point the center of the screen at the floor and try again."
                return
            }
            remove()
            scene.isBuilding = true
            scene.status = "Loading \(urdf.name)…"
            buildTask = Task { [weak self] in
                guard let self else { return }
                let entity = await RobotEntity(robot: urdf, meshes: meshes)
                guard !Task.isCancelled, let arView = self.arView else { return }
                let anchor = AnchorEntity(world: hit.worldTransform)
                anchor.addChild(entity.root)
                let gizmo = Self.makeGizmo()
                anchor.addChild(gizmo)
                arView.scene.addAnchor(anchor)
                self.anchor = anchor
                self.gizmo = gizmo
                alignment = AlignmentTransform.from(worldTransform: hit.worldTransform)
                robot = entity
                mapper = JointStateMapper(robot: urdf)
                smoother = JointSmoother(
                    tau: 0.06,
                    wrapAroundJoints: Set(urdf.joints.filter { $0.type == .continuous }.map(\.name))
                )
                lastStamp = nil
                scene.isBuilding = false
                scene.isPlaced = true
                scene.placedRobotName = urdf.name
                scene.placeholders = entity.placeholders
                scene.status = entity.placeholders.isEmpty
                    ? "\(urdf.name) placed — \(entity.linkEntities.count) links"
                    : "\(urdf.name) placed; \(entity.placeholders.count) mesh(es) missing → placeholders"
                log
                    .info(
                        "placed \(urdf.name, privacy: .public) with \(entity.placeholders.count) placeholders"
                    )
            }
        }

        private func remove() {
            buildTask?.cancel()
            buildTask = nil
            if let anchor {
                arView?.scene.removeAnchor(anchor)
            }
            anchor = nil
            gizmo = nil
            alignment = nil
            robot = nil
            mapper = nil
            scene.isPlaced = false
            scene.isBuilding = false
            scene.isAligning = false
            scene.placedRobotName = nil
            scene.placeholders = []
        }

        // MARK: Alignment gizmo

        /// A translucent cyan disc plus a red heading arrow, both unlit so they read clearly
        /// regardless of scene lighting — the thing the user actually looks at while aligning,
        /// since the robot model alone gave no visual sense of "you're in align mode" or which
        /// way is forward.
        private static func makeGizmo() -> Entity {
            let root = Entity()
            root.name = "alignment-gizmo"
            let disc = ModelEntity(
                mesh: .generateCylinder(height: 0.005, radius: 0.22),
                materials: [UnlitMaterial(color: UIColor.cyan.withAlphaComponent(0.55))]
            )
            let arrow = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.04, 0.012, 0.22)),
                materials: [UnlitMaterial(color: UIColor.red)]
            )
            arrow.position = SIMD3(0, 0.003, -0.15) // offset along local -Z (forward, see yaw convention)
            root.addChild(disc)
            root.addChild(arrow)
            root.isEnabled = false
            return root
        }

        /// Called every `updateUIView`; reacts to `scene.isAligning` flipping (show the gizmo)
        /// rather than a one-shot request, since this is a persistent mode.
        func syncAligningState() {
            guard scene.isAligning != wasAligning else { return }
            wasAligning = scene.isAligning
            gizmo?.isEnabled = scene.isAligning
        }

        /// Axis-select-then-drag, not a free 2D/3D gesture: `scene.alignAxis` (set by UI
        /// buttons) picks X / Z / yaw, and a single plain screen-space pan delta moves along
        /// just that axis — `translation.x` scaled by a constant, the same regardless of which
        /// axis is selected. No raycasting of any kind is involved, which is deliberate: an
        /// earlier version raycast the floor under the touch point to drive a free 2D drag, and
        /// that was unreliable in practice (see the M4 findings in docs/testing.md) — shallow
        /// viewing angles amplified small finger movements into large jumps, and depended on
        /// ARKit's plane estimation being accurate exactly where the user was touching.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard scene.isAligning, let arView, recognizer.state == .began || recognizer.state == .changed
            else { return }
            let dx = Float(recognizer.translation(in: arView).x)
            recognizer.setTranslation(.zero, in: arView) // consume it — this is a delta, not a total

            switch scene.alignAxis {
            case .x: alignment = alignment?.translatedLocally(byX: dx * Self.panMetersPerPoint)
            case .z: alignment = alignment?.translatedLocally(byZ: dx * Self.panMetersPerPoint)
            case .yaw: alignment = alignment?.rotated(byYaw: dx * Self.panRadiansPerPoint)
            }
            applyAlignmentToAnchor()
        }

        // Tuned to feel like the reference app's block-alignment drag (same order of magnitude):
        // ~1000 screen points of drag per metre of translation, ~100 points per radian of yaw.
        private static let panMetersPerPoint: Float = 1 / 1000
        private static let panRadiansPerPoint: Float = 1 / 100

        private func applyAlignmentToAnchor() {
            guard let anchor, let alignment else { return }
            anchor.transform = Transform(matrix: alignment.transform)
        }

        // MARK: Scanning

        func handleScanRequest() {
            guard let request = scanScene.request else { return }
            scanScene.request = nil
            switch request {
            case .capture: captureScan()
            case .clear: clearScan()
            case .upload: uploadScan()
            }
        }

        /// Pulls vertices out of every `ARMeshAnchor` currently in the session's fused scene
        /// mesh (LiDAR-backed, already deduplicated by ARKit across overlapping frames — a much
        /// better "static point cloud of the environment" source than raw per-frame depth
        /// points) and folds them into the running scan, in raw AR-world coordinates. Neither
        /// the ROS axis rotation nor the robot-alignment registration is applied here — both
        /// happen together at upload time in `uploadScan`, using whatever the CURRENT alignment
        /// is then, so re-aligning the robot after a capture doesn't require re-scanning.
        private func captureScan() {
            guard let frame = arView?.session.currentFrame else {
                scanScene.status = "No AR frame yet — point the camera around first."
                return
            }
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            guard !meshAnchors.isEmpty else {
                scanScene.status = "No scene mesh yet — move around a bit so LiDAR can see the room."
                return
            }

            var bx: [Float] = [], by: [Float] = [], bz: [Float] = []
            for meshAnchor in meshAnchors {
                for worldVertex in Self.worldVertices(of: meshAnchor) {
                    bx.append(worldVertex.x); by.append(worldVertex.y); bz.append(worldVertex.z)
                }
            }
            let batch = PointCloud(x: bx, y: by, z: bz, confidence: [UInt8](repeating: 2, count: bx.count))

            scanCloud.append(batch)
            scanCloud = VoxelFilter.downsample(scanCloud, voxelSize: scanVoxelSize)
            scanScene.pointCount = scanCloud.count
            scanScene.status = "\(scanCloud.count) points scanned so far."
        }

        private static func worldVertices(of meshAnchor: ARMeshAnchor) -> [SIMD3<Float>] {
            let source = meshAnchor.geometry.vertices
            let transform = meshAnchor.transform
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(source.count)
            let buffer = source.buffer.contents()
            for i in 0 ..< source.count {
                let vertexPointer = buffer.advanced(by: source.offset + i * source.stride)
                let local = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world = transform * SIMD4(local, 1)
                points.append(SIMD3(world.x, world.y, world.z))
            }
            return points
        }

        private func clearScan() {
            scanCloud = .empty
            scanScene.pointCount = 0
            scanScene.lastUploadSummary = nil
            scanScene.status = "Scan cleared. Move around, then capture again."
        }

        private func uploadScan() {
            guard !scanCloud.isEmpty else {
                scanScene.status = "Nothing to upload yet — capture a scan first."
                return
            }
            guard let arBridgeURL = session.settings.arBridgeURL else {
                scanScene.status = "Connect to ar_bridge first (see connection settings)."
                return
            }

            // Registration: if the robot has been placed/aligned, re-express every point
            // relative to that alignment (position AND yaw — full registration, not M3's
            // translation-only stopgap) before rotating into ROS axis convention, so the cloud
            // lands in base_link where the gizmo says the robot actually is. Recomputed from
            // whatever the CURRENT alignment is at upload time, not baked in at capture time,
            // so re-aligning doesn't require re-scanning.
            let frameId: String
            let toUpload: PointCloud
            if let alignment {
                toUpload = CloudRegistration.registering(scanCloud, against: alignment)
                frameId = "base_link"
            } else {
                toUpload = CloudRegistration.rotatedToROSAxes(scanCloud)
                frameId = "map"
                scanScene.status = "No robot placed — uploading unregistered (frame \"map\")."
            }

            let client = ARBridgeClient(baseURL: arBridgeURL)
            let data = PLYCodec.encode(toUpload)
            scanScene.isUploading = true
            scanScene.status = "Uploading \(toUpload.count) points…"
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // Fixed name + `.replace`: the client already holds the full accumulated,
                    // voxel-filtered state, so every upload fully replaces the latched topic and
                    // the on-disk file rather than relying on the server's append accumulator.
                    let result = try await client.uploadCloud(data, frameId: frameId, name: "live_scan")
                    scanScene.lastUploadSummary = "\(result.points) pts → \(result.topic) (\(frameId))"
                    scanScene.status = "Uploaded \(result.points) points."
                } catch {
                    log.error("cloud upload failed: \(String(describing: error), privacy: .public)")
                    scanScene.status = "Upload failed: \(error)"
                }
                scanScene.isUploading = false
            }
        }

        // MARK: Per-frame

        private func tick(dt: TimeInterval) {
            guard let robot, var mapper else { return }
            if let js = session.jointState, js.header.stamp != lastStamp {
                lastStamp = js.header.stamp
                mapper.apply(js)
                self.mapper = mapper
                smoother.setTargets(mapper.positions)
            }
            robot.update(jointPositions: smoother.step(dt: dt))
        }
    }
}
