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
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.handleRequest()
        context.coordinator.handleScanRequest()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, scene: scene, scanScene: scanScene)
    }

    /// Owns the robot entity and drives it from `/joint_states` on every rendered frame.
    @MainActor
    final class Coordinator {
        private let session: ROSSession
        private let scene: RobotScene
        private let scanScene: ScanScene
        private weak var arView: ARView?
        private var anchor: AnchorEntity?
        private var robot: RobotEntity?
        private var mapper: JointStateMapper?
        private var smoother = JointSmoother(tau: 0.06)
        private var lastStamp: ROSTime?
        private var updateSubscription: Cancellable?
        private var buildTask: Task<Void, Never>?
        private var uploadTask: Task<Void, Never>?
        private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ARContainer")

        /// Accumulated across `.capture` requests, already in the ROS/`base_link` frame
        /// convention (M4 alignment not built yet, so really "AR session origin" for now — see
        /// `ARBridgeClient.uploadCloud`). Re-voxelized after every capture so repeated taps don't
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
                arView.scene.addAnchor(anchor)
                self.anchor = anchor
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
            robot = nil
            mapper = nil
            scene.isPlaced = false
            scene.isBuilding = false
            scene.placedRobotName = nil
            scene.placeholders = []
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
        /// points), converts world space → ROS, and folds them into the running scan.
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

            var batch = PointCloud.empty
            var bx: [Float] = [], by: [Float] = [], bz: [Float] = []
            for meshAnchor in meshAnchors {
                for worldVertex in Self.worldVertices(of: meshAnchor) {
                    let rosPoint = FrameConventions.toROS(point: worldVertex)
                    bx.append(rosPoint.x); by.append(rosPoint.y); bz.append(rosPoint.z)
                }
            }
            batch = PointCloud(x: bx, y: by, z: bz, confidence: [UInt8](repeating: 2, count: bx.count))

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
            let client = ARBridgeClient(baseURL: arBridgeURL)
            let data = PLYCodec.encode(scanCloud)
            scanScene.isUploading = true
            scanScene.status = "Uploading \(scanCloud.count) points…"
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // Fixed name + `.replace`: the client already holds the full accumulated,
                    // voxel-filtered state, so every upload fully replaces the latched topic and
                    // the on-disk file rather than relying on the server's append accumulator.
                    let result = try await client.uploadCloud(data, frameId: "map", name: "live_scan")
                    scanScene.lastUploadSummary = "\(result.points) pts → \(result.topic)"
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
