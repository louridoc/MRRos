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

    /// Shared by first launch and by restoring a saved alignment, so a restored session is
    /// configured identically apart from `initialWorldMap`.
    static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        return config
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.sceneUnderstanding.options = [.occlusion]
        view.debugOptions = [.showWorldOrigin]
        view.session.run(Self.makeConfiguration())
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
        /// Fixed at the AR world origin for the entity's whole lifetime and never touched again
        /// after creation — `AnchorEntity` represents a point ARKit tracks, and mutating its
        /// `.transform` to drag the robot turned out to fight (or at least raised real doubt
        /// about fighting) with RealityKit's own anchor bookkeeping, which is what the repeated
        /// "snaps below the floor" reports traced back to. `alignmentRoot` is a plain child
        /// `Entity` instead — nothing about a plain entity's transform is special, so there's
        /// nothing for it to fight with.
        private var anchor: AnchorEntity?
        /// Child of `anchor`; its LOCAL transform (== world transform, since `anchor` sits at
        /// identity) is `alignment.transform` — this is the thing the gizmo actually moves.
        /// Holds the robot and the gizmo decoration as ITS children.
        private var alignmentRoot: Entity?
        /// `base_link` triad (red X, green Y, blue Z) shown while aligning — a child of
        /// `alignmentRoot`, so it sits exactly at the base and turns with it.
        private var gizmo: BaseLinkTriad?
        /// Where `base_link` is in AR world space — seeded from the placement raycast, then
        /// refined live by the gizmo gestures while `scene.isAligning`. Scan uploads register
        /// against this, recomputed fresh at upload time (see `uploadScan`).
        private var alignment: AlignmentTransform?
        private var wasAligning = false
        private var highlightedAxis: RobotScene.AlignAxis?
        /// `nil` only if Application Support is unavailable — saving/restoring then just reports so.
        private let alignmentStore = try? AlignmentStore.standard()
        /// Set by `restoreSaved`; cleared once ARKit relocalizes and the robot is rebuilt. Frames
        /// timestamped before `restoreStartedAt` belong to the pre-restore session (tracking
        /// `.normal`, possibly still holding an old base_link anchor) and must be ignored.
        private var pendingRestore = false
        private var restoreStartedAt: TimeInterval = 0
        /// Set once the base_link anchor has been added; the map is captured on the frame where
        /// that anchor first appears (an added anchor isn't in the session until a later frame).
        private var pendingSave: (info: SavedAlignmentInfo, anchorID: UUID)?
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
            scene.savedAlignment = alignmentStore?.info()
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
            case .restoreSaved: restoreSaved()
            case .forgetSaved: forgetSaved()
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
            build(urdf, at: AlignmentTransform.from(worldTransform: hit.worldTransform), restored: false)
        }

        /// Builds the robot with `base_link` at `seeded` — from a fresh floor raycast, or from the
        /// saved anchor after relocalizing.
        private func build(_ urdf: URDFRobot, at seeded: AlignmentTransform, restored: Bool) {
            remove()
            scene.isBuilding = true
            scene.status = "Loading \(urdf.name)…"
            buildTask = Task { [weak self] in
                guard let self else { return }
                let entity = await RobotEntity(robot: urdf, meshes: meshes)
                guard !Task.isCancelled, let arView else { return }

                let anchor = AnchorEntity(world: matrix_identity_float4x4)
                let root = Entity()
                let gizmo = BaseLinkTriad()
                root.addChild(entity.root)
                root.addChild(gizmo.root)
                anchor.addChild(root)
                arView.scene.addAnchor(anchor)
                root.transform = Transform(matrix: seeded.transform)

                self.anchor = anchor
                alignmentRoot = root
                self.gizmo = gizmo
                highlightedAxis = nil // fresh triad: let syncAligningState highlight it
                alignment = seeded
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
                let verb = restored ? "restored — check it overlays the real robot" : "placed"
                scene.status = entity.placeholders.isEmpty
                    ? "\(urdf.name) \(verb)"
                    : "\(urdf.name) \(verb); \(entity.placeholders.count) mesh(es) missing → placeholders"
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
            alignmentRoot = nil
            gizmo = nil
            alignment = nil
            robot = nil
            mapper = nil
            scene.isPlaced = false
            scene.isBuilding = false
            scene.isAligning = false
            scene.placedRobotName = nil
            scene.placeholders = []
            // Removing (or placing by hand, which removes first) abandons a restore that hasn't
            // relocalized yet and any save still waiting for its anchor.
            pendingRestore = false
            scene.isRestoring = false
            pendingSave = nil
            // Leave align mode here rather than via syncAligningState, so removing mid-align
            // isn't mistaken for "Done" (which saves).
            if wasAligning {
                wasAligning = false
                arView?.environment.sceneUnderstanding.options = [.occlusion]
            }
        }

        // MARK: Save / restore alignment (M4b)

        /// Drops a `base_link` ARAnchor at the current alignment; `tick` captures the world map
        /// once it's in the session. Only when ARKit reports the map as mapped/extending —
        /// earlier maps relocalize poorly or not at all.
        private func saveAlignment() {
            guard let arView, let alignment, alignmentStore != nil,
                  let frame = arView.session.currentFrame
            else { return }
            guard frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending else {
                scene.status = "Aligned, but not saved: ARKit hasn't mapped enough of the room yet. "
                    + "Move around the robot, then Align → Done again."
                return
            }
            for old in frame.anchors where old.name == AlignmentStore.anchorName {
                arView.session.remove(anchor: old)
            }
            // Tracked by identifier, not name: frames from before this call still contain the
            // anchor being replaced, which must not satisfy the capture check.
            let anchor = ARAnchor(name: AlignmentStore.anchorName, transform: alignment.transform)
            arView.session.add(anchor: anchor)
            pendingSave = (
                SavedAlignmentInfo(robotName: scene.placedRobotName, savedAt: Date()),
                anchor.identifier
            )
            scene.status = "Saving alignment…"
        }

        private func capturePendingSave(_ frame: ARFrame) {
            guard let (info, anchorID) = pendingSave, let arView, let store = alignmentStore,
                  frame.anchors.contains(where: { $0.identifier == anchorID })
            else { return }
            pendingSave = nil
            // @Sendable: ARKit calls this off the main actor; archiving/writing happens there and
            // only the outcome hops back.
            arView.session.getCurrentWorldMap { @Sendable [weak self] map, error in
                let outcome: String?
                do {
                    guard let map
                    else { throw error ?? AlignmentStoreError.corrupt("ARKit returned no world map") }
                    // Exactly the anchor just placed — not a stale one, not two of them.
                    let robotAnchors = map.anchors.filter { $0.name == AlignmentStore.anchorName }
                    guard robotAnchors.count == 1, robotAnchors[0].identifier == anchorID else {
                        throw AlignmentStoreError
                            .corrupt("world map was captured without the current robot anchor")
                    }
                    let data = try NSKeyedArchiver.archivedData(
                        withRootObject: map,
                        requiringSecureCoding: true
                    )
                    try store.save(worldMap: data, info: info)
                    outcome = nil
                } catch {
                    outcome = error.localizedDescription
                }
                Task { @MainActor in self?.saveFinished(info: info, error: outcome) }
            }
        }

        private func saveFinished(info: SavedAlignmentInfo, error: String?) {
            if let error {
                scene.status = "Couldn't save alignment: \(error)"
            } else {
                scene.savedAlignment = info
                scene.status = "Alignment saved — restore it next time with \"Restore saved\"."
            }
        }

        /// Re-runs the session from the saved map; `tick` rebuilds the robot at the saved anchor
        /// once tracking is back to `.normal` (ARKit holds `.limited(.relocalizing)` until it has
        /// matched the map). Clears the scan: points captured before relocalization would be in
        /// an unrelated frame.
        private func restoreSaved() {
            guard let arView, let store = alignmentStore else { return }
            guard let urdf = session.urdfRobot else {
                scene.status = "Connect first — the robot description is needed to rebuild it."
                return
            }
            let map: ARWorldMap
            let info: SavedAlignmentInfo
            do {
                guard let saved = try store.load() else {
                    scene.savedAlignment = nil
                    return
                }
                guard let unarchived = try NSKeyedUnarchiver.unarchivedObject(
                          ofClass: ARWorldMap.self,
                          from: saved.worldMap
                      ),
                      unarchived.anchors.contains(where: { $0.name == AlignmentStore.anchorName })
                else {
                    scene.status = "Saved alignment is unusable (no robot anchor in it) — align and save again."
                    return
                }
                map = unarchived
                info = saved.info
            } catch {
                scene.status = "Couldn't read saved alignment: \(error.localizedDescription)"
                return
            }

            remove()
            clearScan(resetReconstruction: false)
            let config = ARContainerView.makeConfiguration()
            config.initialWorldMap = map
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            restoreStartedAt = ProcessInfo.processInfo.systemUptime // same clock as ARFrame.timestamp
            pendingRestore = true
            scene.isRestoring = true
            var status = "Relocalizing — point the phone at the area where you aligned the robot."
            if let saved = info.robotName, saved != urdf.name {
                status += " (Saved for \(saved), connected robot is \(urdf.name).)"
            }
            scene.status = status
        }

        private func completePendingRestore(_ frame: ARFrame) {
            guard frame.timestamp > restoreStartedAt,
                  case .normal = frame.camera.trackingState,
                  let anchor = frame.anchors.first(where: { $0.name == AlignmentStore.anchorName }),
                  let urdf = session.urdfRobot
            else { return }
            pendingRestore = false
            scene.isRestoring = false
            build(urdf, at: AlignmentTransform.from(worldTransform: anchor.transform), restored: true)
        }

        private func forgetSaved() {
            do {
                try alignmentStore?.clear()
                scene.savedAlignment = nil
                scene.status = "Saved alignment forgotten."
            } catch {
                scene.status = "Couldn't forget saved alignment: \(error.localizedDescription)"
            }
        }

        // MARK: Alignment gizmo

        /// Called every `updateUIView` (which also makes SwiftUI's observation re-run it when
        /// `isAligning`/`alignAxis` change). Mode entry/exit and axis highlight are separate so
        /// switching axes doesn't redo the mode toggles.
        func syncAligningState() {
            if scene.isAligning != wasAligning {
                let finishedAligning = wasAligning && !scene.isAligning
                wasAligning = scene.isAligning
                if finishedAligning {
                    saveAlignment()
                }
                gizmo?.root.isEnabled = scene.isAligning
                // Translucent robot so the triad at the base reads through it. Occlusion off while
                // aligning: the triad sits exactly where the REAL robot's base is, so the real
                // robot's LiDAR occlusion mesh would otherwise hide it.
                robot?.root.components.set(OpacityComponent(opacity: scene.isAligning ? 0.45 : 1))
                arView?.environment.sceneUnderstanding.options = scene.isAligning ? [] : [.occlusion]
            }
            if scene.alignAxis != highlightedAxis {
                highlightedAxis = scene.alignAxis
                gizmo?.highlight(scene.alignAxis)
            }
        }

        /// Axis-select-then-drag in `base_link` axes. For X/Y/Z the drag is measured ALONG the
        /// selected arrow as it appears on screen, scaled so the base follows the finger; yaw
        /// uses plain horizontal drag. No raycasting — see the M4 findings in docs/testing.md
        /// for why touch-point floor raycasts were abandoned.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard scene.isAligning, let arView, let alignment,
                  recognizer.state == .began || recognizer.state == .changed
            else { return }
            let t = recognizer.translation(in: arView)
            recognizer.setTranslation(.zero, in: arView) // consume it — a delta, not a total

            switch scene.alignAxis {
            case .x, .y, .z:
                let axis: SIMD3<Float> = switch scene.alignAxis {
                case .x: SIMD3(1, 0, 0)
                case .y: SIMD3(0, 1, 0)
                default: SIMD3(0, 0, 1)
                }
                // Fallback drag direction when the axis is foreshortened on screen: sideways for
                // the floor axes, up/down for Z (screen y grows downward, hence the minus).
                let fallbackPoints = scene.alignAxis == .z ? -Float(t.y) : Float(t.x)
                let m = Self.metres(
                    dragging: t, alongBaseLinkAxis: axis, fallbackPoints: fallbackPoints, of: alignment,
                    in: arView
                )
                self.alignment = alignment.translatedInBaseLink(by: axis * m)
            case .yaw:
                self.alignment = alignment.rotated(byYaw: Float(t.x) * Self.panRadiansPerPoint)
            }
            applyAlignmentToAnchor()
        }

        /// How far (metres) a screen drag `t` moves along a `base_link` axis: project a short
        /// segment of that axis to screen, take the drag's component along it, and divide by the
        /// segment's on-screen pixels-per-metre — so the base tracks the finger along the arrow
        /// regardless of distance or viewing angle. Falls back to `fallbackPoints` at a fixed
        /// scale when the axis is foreshortened (pointing at the camera) or the base is off-screen.
        private static func metres(
            dragging t: CGPoint,
            alongBaseLinkAxis axis: SIMD3<Float>,
            fallbackPoints: Float,
            of alignment: AlignmentTransform,
            in arView: ARView
        ) -> Float {
            let segment: Float = 0.25
            let tip = alignment.position + alignment.worldVector(fromBaseLink: axis) * segment
            if let p0 = arView.project(alignment.position), let p1 = arView.project(tip) {
                let onScreen = SIMD2(Float(p1.x - p0.x), Float(p1.y - p0.y))
                let pixels = simd_length(onScreen)
                if pixels > 20 {
                    let along = simd_dot(SIMD2(Float(t.x), Float(t.y)), onScreen / pixels)
                    return along * segment / pixels
                }
            }
            return fallbackPoints * panMetersPerPoint
        }

        // Fallback/yaw scales, same order of magnitude as the reference app's block drag:
        // ~1000 screen points per metre, ~100 points per radian.
        private static let panMetersPerPoint: Float = 1 / 1000
        private static let panRadiansPerPoint: Float = 1 / 100

        private func applyAlignmentToAnchor() {
            guard let alignmentRoot, let alignment else { return }
            alignmentRoot.transform = Transform(matrix: alignment.transform)
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
            guard source.format == .float3 else { return [] }
            let transform = meshAnchor.transform
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(source.count)
            let base = UnsafeRawPointer(source.buffer.contents()).advanced(by: source.offset)
            for i in 0 ..< source.count {
                // ARKit packs vertices as 3 floats (12 bytes). Never read them as SIMD3<Float>:
                // that type is 16 bytes / 16-aligned, so it misaligns and over-reads the last
                // vertex past the buffer end — EXC_BAD_ACCESS whenever that end hits a page
                // boundary (crashed on a ~98k-point scan).
                let (x, y, z) = base.loadUnaligned(
                    fromByteOffset: i * source.stride, as: (Float, Float, Float).self
                )
                let world = transform * SIMD4(x, y, z, 1)
                points.append(SIMD3(world.x, world.y, world.z))
            }
            return points
        }

        /// `resetReconstruction`: also restart ARKit's scene mesh, so the next Capture only contains
        /// what's scanned from now on — Capture harvests ARKit's whole fused mesh, so clearing only
        /// our buffer brought every previously-seen surface straight back. Tracking is NOT reset:
        /// the world frame, the alignment and the placed robot all stay valid. Off for the restore
        /// path, which has just re-run the session from the saved map itself.
        private func clearScan(resetReconstruction: Bool = true) {
            if resetReconstruction, let arView,
               let config = arView.session.configuration?.copy() as? ARWorldTrackingConfiguration
            {
                config.initialWorldMap = nil // don't trigger a second relocalization
                arView.session.run(config, options: [.resetSceneReconstruction])
            }
            scanCloud = .empty
            scanScene.pointCount = 0
            scanScene.lastUploadSummary = nil
            scanScene.status = "Scan cleared. Move around, then capture again."
            // A user Clear also empties the ROS side (ar_bridge publishes an empty cloud and
            // clears MoveIt's octomap) — otherwise RViz/MoveIt keep the last upload until the
            // next one. The restore path doesn't: it isn't the user asking to empty the scene.
            guard resetReconstruction, let arBridgeURL = session.settings.arBridgeURL else { return }
            let client = ARBridgeClient(baseURL: arBridgeURL)
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                do {
                    try await client.clearCloud(name: "live_scan")
                    self?.scanScene.status = "Scan cleared here and on ROS. Move around, then capture again."
                } catch {
                    self?.log.error("cloud clear failed: \(String(describing: error), privacy: .public)")
                    self?.scanScene.status = "Scan cleared here; couldn't clear ROS side: \(error)"
                }
            }
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
            if pendingRestore || pendingSave != nil, let frame = arView?.session.currentFrame {
                if pendingRestore {
                    completePendingRestore(frame)
                }
                if pendingSave != nil {
                    capturePendingSave(frame)
                }
            }
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
