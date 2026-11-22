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
import SceneLibrary
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
        // We configure and run the session ourselves (scene reconstruction, scene depth,
        // restores, mesh resets); RealityKit's automatic configuration would otherwise re-run it
        // with its own config whenever sceneUnderstanding options change (e.g. entering align mode).
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
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
        /// Scan crop box in base_link. Kept across re-placements; defaults to a workspace around
        /// the base: ±0.8 m in X/Y, from 5 cm below the base to 1.4 m up.
        private var crop = BaseLinkBox(center: SIMD3(0, 0, 0.675), half: SIMD3(0.8, 0.8, 0.725))
        /// Exclusion boxes in base_link, by stable ID (`scanScene.exclusionIDs` keeps the order).
        /// Data survives re-placing the robot (visuals are rebuilt); a user Clear deletes them.
        private var exclusions: [Int: BaseLinkBox] = [:]
        private var nextExclusionID = 1
        private static let minBoxHalf: Float = 0.025
        private static let newExclusionHalf: Float = 0.15
        private var cropVisual: BoxVisual?
        private var exclusionVisuals: [Int: BoxVisual] = [:]
        private var wasCropEnabled = false
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
        /// Drawn at a world-fixed anchor so it exists whether or not a robot is placed.
        private let preview = ScanPreview()
        /// Heavy scan work runs here, off the main thread (see ScanProcessing.swift).
        private let processor: ScanProcessor
        /// Bumped by Clear; captures/previews started under an older epoch are discarded.
        private var scanEpoch = 0
        /// Bumped per preview request; only the newest result is shown.
        private var previewGeneration = 0
        private var captureTask: Task<Void, Never>?
        private var previewTask: Task<Void, Never>?
        private var lastCaptureNote = ""
        /// Robot link boxes (base_link) from a loaded scene's scan time: removed on top of the
        /// live robot, so where the real robot WAS when scanned can't come back as an obstacle.
        private var sceneRobotBoxes: [StoredBox] = []
        /// `nil` only if Documents is unavailable — the Scenes sheet then reports it.
        private let sceneStore = try? SceneStore.standard()
        /// Re-created on every redraw, never kept from app start: RealityKit backs world anchors
        /// with ARKit anchors, and a restore (`.resetTracking, .removeExistingAnchors`) moves the
        /// world frame and drops them — an anchor made at launch left the preview displaced by
        /// exactly that jump. Same lifetime rule as the robot's anchor.
        private var previewAnchor: AnchorEntity?
        /// Matches MoveIt's sensors_3d padding_offset so the phone and MoveIt agree on what
        /// "the robot" is (MoveIt's filter is exact-mesh, ours is per-link bounding boxes).
        nonisolated private static let robotPadding: Float = 0.03
        /// When Clear last asked ARKit to restart its scene mesh — shown on Capture so a device
        /// test can tell whether the reset actually took (a capture right after it should be tiny).
        private var lastMeshReset: Date?
        private static let scanVoxelSize: Float = 0.02

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
            processor = ScanProcessor(voxelSize: Self.scanVoxelSize)
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
                let cropVisual = BoxVisual(color: .systemYellow, fillOpacity: 0.08)
                cropVisual.update(crop)
                cropVisual.root.isEnabled = scanScene.cropEnabled
                root.addChild(entity.root)
                root.addChild(gizmo.root)
                root.addChild(cropVisual.root)
                anchor.addChild(root)
                arView.scene.addAnchor(anchor)
                root.transform = Transform(matrix: seeded.transform)

                self.anchor = anchor
                alignmentRoot = root
                self.gizmo = gizmo
                self.cropVisual = cropVisual
                exclusionVisuals = [:]
                for (id, box) in exclusions {
                    exclusionVisuals[id] = makeExclusionVisual(box, in: root)
                }
                refreshBoxSelection()
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
                refreshPreview()
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
            cropVisual = nil
            exclusionVisuals = [:]
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
                    refreshPreview()
                }
                // Translucent robot so the triad at the base reads through it. Occlusion off while
                // aligning: the triad sits exactly where the REAL robot's base is, so the real
                // robot's LiDAR occlusion mesh would otherwise hide it.
                robot?.root.components.set(OpacityComponent(opacity: scene.isAligning ? 0.45 : 1))
                arView?.environment.sceneUnderstanding.options = scene.isAligning ? [] : [.occlusion]
            }
            // While editing a box the triad moves to that box's centre and turns with its yaw, so
            // the arrows are exactly the axes a drag acts along; otherwise it marks the base.
            gizmo?.root.isEnabled = scene.isAligning || scanScene.isEditingBoxes
            let wanted: RobotScene.AlignAxis = if scanScene.isEditingBoxes {
                switch scanScene.editAxis {
                case .x: .x
                case .y: .y
                case .z: .z
                }
            } else {
                scene.alignAxis
            }
            if wanted != highlightedAxis {
                highlightedAxis = wanted
                gizmo?.highlight(wanted)
            }
            if scanScene.cropEnabled != wasCropEnabled {
                wasCropEnabled = scanScene.cropEnabled
                cropVisual?.root.isEnabled = scanScene.cropEnabled
                updateCropSummary()
                refreshPreview()
            }
            refreshBoxSelection()
        }

        /// Axis-select-then-drag in `base_link` axes. For X/Y/Z the drag is measured ALONG the
        /// selected arrow as it appears on screen, scaled so the base follows the finger; yaw
        /// uses plain horizontal drag. No raycasting — see the M4 findings in docs/testing.md
        /// for why touch-point floor raycasts were abandoned.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let arView, let alignment else { return }
            if scanScene.isEditingBoxes {
                dragBox(recognizer, in: arView, alignment: alignment)
                return
            }
            guard scene.isAligning, recognizer.state == .began || recognizer.state == .changed
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
                    dragging: t, along: alignment.worldVector(fromBaseLink: axis), from: alignment.position,
                    fallbackPoints: fallbackPoints, in: arView
                )
                self.alignment = alignment.translatedInBaseLink(by: axis * m)
            case .yaw:
                self.alignment = alignment.rotated(byYaw: Float(t.x) * Self.panRadiansPerPoint)
            }
            applyAlignmentToAnchor()
        }

        /// Box editing (crop or exclusion): same axis-select-then-drag as alignment, along the
        /// selected box's OWN axes from its centre. Move shifts it, Size grows/shrinks it
        /// symmetrically, Rotate (exclusion boxes) turns it about its vertical axis. The scan is
        /// re-filtered when the finger lifts, not per event — re-classifying 50k+ points and
        /// rebuilding the preview at 60 Hz would stutter.
        private func dragBox(_ recognizer: UIPanGestureRecognizer, in arView: ARView, alignment: AlignmentTransform) {
            switch recognizer.state {
            case .ended, .cancelled:
                updateCropSummary()
                refreshPreview()
                return
            case .began, .changed:
                break
            default:
                return
            }
            guard var box = selectedBox() else { return }
            let t = recognizer.translation(in: arView)
            recognizer.setTranslation(.zero, in: arView)

            if scanScene.editMode == .rotate {
                guard case .exclusion = scanScene.editTarget else { return } // crop stays square
                box.yaw += Float(t.x) * Self.panRadiansPerPoint
            } else {
                let i = switch scanScene.editAxis {
                case .x: 0
                case .y: 1
                case .z: 2
                }
                let axis = box.axisInBaseLink(i)
                let fallbackPoints = scanScene.editAxis == .z ? -Float(t.y) : Float(t.x)
                let m = Self.metres(
                    dragging: t, along: alignment.worldVector(fromBaseLink: axis),
                    from: alignment.worldPoint(fromBaseLink: box.center), fallbackPoints: fallbackPoints, in: arView
                )
                if scanScene.editMode == .move {
                    box.center += axis * m
                } else {
                    box.half[i] = max(Self.minBoxHalf, box.half[i] + m / 2)
                }
            }
            setSelectedBox(box)
        }

        private func selectedBox() -> BaseLinkBox? {
            switch scanScene.editTarget {
            case .crop: scanScene.cropEnabled ? crop : nil
            case let .exclusion(id): exclusions[id]
            }
        }

        private func setSelectedBox(_ box: BaseLinkBox) {
            switch scanScene.editTarget {
            case .crop:
                crop = box
                cropVisual?.update(box)
            case let .exclusion(id):
                exclusions[id] = box
                exclusionVisuals[id]?.update(box)
            }
            placeTriad()
        }

        /// Dim every box but the one being edited, and put the triad on it.
        private func refreshBoxSelection() {
            let editing = scanScene.isEditingBoxes
            cropVisual?.setSelected(editing && scanScene.editTarget == .crop)
            for (id, visual) in exclusionVisuals {
                visual.setSelected(editing && scanScene.editTarget == .exclusion(id))
            }
            placeTriad()
        }

        /// The triad lives under the alignment root and draws in base_link via its own ROS frame;
        /// to put it on a box, conjugate the box's base_link pose into that parent's AR axes.
        private func placeTriad() {
            guard let gizmo else { return }
            if scanScene.isEditingBoxes, let box = selectedBox() {
                let m = FrameConventions.rosToARFloat * box.baseLinkFromBox * FrameConventions.arToROSFloat
                gizmo.root.transform = Transform(matrix: m)
            } else {
                gizmo.root.transform = .identity
            }
        }

        private func makeExclusionVisual(_ box: BaseLinkBox, in parent: Entity) -> BoxVisual {
            let visual = BoxVisual(color: .systemOrange, fillOpacity: 0.12)
            visual.update(box)
            parent.addChild(visual.root)
            return visual
        }

        /// New exclusion box centred where the screen centre hits a surface (or 1 m ahead of the
        /// camera if nothing is hit), axis-aligned to base_link; selected for editing right away.
        private func addExclusion() {
            guard let arView, let alignment, let root = alignmentRoot else {
                scanScene.status = "Place the robot first — exclusion boxes are attached to it."
                return
            }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            let world: SIMD3<Float>
            if let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first {
                let t = hit.worldTransform.columns.3
                world = SIMD3(t.x, t.y, t.z)
            } else {
                let cam = arView.cameraTransform.matrix
                let ahead = cam * SIMD4<Float>(0, 0, -1, 1)
                world = SIMD3(ahead.x, ahead.y, ahead.z)
            }
            let box = BaseLinkBox(
                center: alignment.baseLinkPoint(fromWorld: world), half: SIMD3(repeating: Self.newExclusionHalf)
            )
            let id = nextExclusionID
            nextExclusionID += 1
            exclusions[id] = box
            exclusionVisuals[id] = makeExclusionVisual(box, in: root)
            scanScene.exclusionIDs.append(id)
            scanScene.editTarget = .exclusion(id)
            scanScene.isEditingBoxes = true
            scene.isAligning = false
            refreshBoxSelection()
            refreshPreview()
        }

        private func deleteSelectedExclusion() {
            guard case let .exclusion(id) = scanScene.editTarget else { return }
            exclusions[id] = nil
            exclusionVisuals.removeValue(forKey: id)?.root.removeFromParent()
            scanScene.exclusionIDs.removeAll { $0 == id }
            selectFallbackTarget()
            refreshPreview()
        }

        private func removeAllExclusions() {
            for visual in exclusionVisuals.values {
                visual.root.removeFromParent()
            }
            exclusions = [:]
            exclusionVisuals = [:]
            scanScene.exclusionIDs = []
            selectFallbackTarget()
        }

        /// After the selected exclusion goes away: the last remaining one, else the crop box,
        /// else stop editing.
        private func selectFallbackTarget() {
            if let last = scanScene.exclusionIDs.last {
                scanScene.editTarget = .exclusion(last)
            } else {
                scanScene.editTarget = .crop
                if !scanScene.cropEnabled { scanScene.isEditingBoxes = false }
            }
            if scanScene.editTarget == .crop, scanScene.editMode == .rotate {
                scanScene.editMode = .move
            }
            refreshBoxSelection()
        }

        private func updateCropSummary() {
            let size = crop.half * 2
            scanScene.cropSummary = scanScene.cropEnabled
                ? String(format: "crop %.2f × %.2f × %.2f m", size.x, size.y, size.z) : nil
        }

        /// How far (metres) a screen drag `t` moves along a world direction `direction` starting
        /// at world point `origin` (the base for alignment, the box centre for cropping): project
        /// a short segment of it to screen, take the drag's component along it, and divide by the
        /// segment's on-screen pixels-per-metre — so the thing tracks the finger along the arrow
        /// regardless of distance or viewing angle. Falls back to `fallbackPoints` at a fixed
        /// scale when the direction is foreshortened (pointing at the camera) or off-screen.
        private static func metres(
            dragging t: CGPoint,
            along direction: SIMD3<Float>,
            from origin: SIMD3<Float>,
            fallbackPoints: Float,
            in arView: ARView
        ) -> Float {
            let segment: Float = 0.25
            let tip = origin + direction * segment
            if let p0 = arView.project(origin), let p1 = arView.project(tip) {
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
            case .addExclusion: addExclusion()
            case .deleteSelected: deleteSelectedExclusion()
            case let .saveScene(name): saveScene(named: name)
            case let .loadScene(id): loadScene(id)
            case let .uploadScene(id): uploadSavedScene(id)
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
            // Main thread: only copy ARKit's vertex buffers out (one memcpy per mesh piece).
            // Transforming, voxelizing, classifying and preview geometry all happen off it.
            let chunks = meshAnchors.compactMap(MeshChunk.init)
            let vertices = chunks.reduce(0) { $0 + $1.count }
            let since = lastMeshReset.map { String(format: " · mesh reset %.0f s ago", Date().timeIntervalSince($0)) } ?? ""
            lastCaptureNote = "\(meshAnchors.count) ARKit mesh pieces, \(vertices) vertices\(since)"
            scanScene.status = "Processing capture…"
            let epoch = scanEpoch
            let processor = processor
            captureTask = Task { [weak self] in
                let cloud = await processor.add(chunks, epoch: epoch)
                guard let self, epoch == self.scanEpoch else { return } // a Clear happened meanwhile
                scanCloud = cloud
                scanScene.pointCount = cloud.count
                refreshPreview()
            }
        }

        /// `resetReconstruction`: also restart ARKit's scene mesh, so the next Capture only contains
        /// what's scanned from now on — Capture harvests ARKit's whole fused mesh, so clearing only
        /// our buffer brought every previously-seen surface straight back. Tracking is NOT reset:
        /// the world frame, the alignment and the placed robot all stay valid. Off for the restore
        /// path, which has just re-run the session from the saved map itself.
        private func clearScan(resetReconstruction: Bool = true) {
            resetLocalScan(resetReconstruction: resetReconstruction)
            // A user Clear also empties the ROS side (ar_bridge publishes an empty cloud and
            // clears MoveIt's octomap) — otherwise RViz/MoveIt keep the last upload until the
            // next one. The restore path doesn't: it isn't the user asking to empty the scene.
            guard resetReconstruction else { return }
            removeAllExclusions()
            sceneRobotBoxes = []
            scanScene.currentSceneName = nil
            guard let arBridgeURL = session.settings.arBridgeURL else { return }
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

        /// Empties the scan on the phone only (points, preview, counts; optionally ARKit's mesh).
        private func resetLocalScan(resetReconstruction: Bool) {
            if resetReconstruction, let arView {
                // Prefer the running config (keeps everything it has); never skip the reset just
                // because it can't be read back — rebuild ours instead.
                let config = (arView.session.configuration?.copy() as? ARWorldTrackingConfiguration)
                    ?? ARContainerView.makeConfiguration()
                config.initialWorldMap = nil // don't trigger a second relocalization
                arView.session.run(config, options: [.resetSceneReconstruction])
                lastMeshReset = Date()
                log.info("scene reconstruction reset requested")
            }
            scanEpoch += 1
            captureTask?.cancel()
            previewTask?.cancel()
            let epoch = scanEpoch
            let processor = processor
            Task { await processor.release(epoch: epoch) }
            scanCloud = .empty
            preview.clear()
            (scanScene.keptCount, scanScene.robotCount, scanScene.croppedCount) = (0, 0, 0)
            scanScene.pointCount = 0
            scanScene.lastUploadSummary = nil
            scanScene.status = "Scan cleared. Move around, then capture again."
        }

        /// Encoded, filtered upload bodies, prepared off the main thread.
        private struct PreparedUpload: Sendable {
            var frameId: String
            var points: (data: Data, count: Int)?
            var mesh: (data: Data, triangles: Int)?
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

            // Registration: if the robot has been placed/aligned, re-express everything relative
            // to that alignment (position AND yaw) in ROS axes, so it lands in base_link where the
            // gizmo says the robot is. Uses the CURRENT alignment/boxes/robot pose — re-aligning
            // doesn't need a re-scan. Inputs are snapshotted here (boxes need RealityKit);
            // filtering, registration and encoding run off the main thread. Mesh triangles are
            // kept or dropped by their centroid, with exactly the boxes the points use.
            let mode = scanScene.uploadMode
            let cloud = scanCloud
            let crop = cropBox()
            let exclusions = exclusionBoxes()
            let robot = robotBoxes()
            let alignment = alignment
            let processor = processor
            let client = ARBridgeClient(baseURL: arBridgeURL)
            scanScene.isUploading = true
            scanScene.status = "Preparing upload…"
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                let mesh = mode.sendsMesh ? await processor.currentMesh() : ScanMesh.empty
                let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedUpload in
                    var out = PreparedUpload(frameId: alignment == nil ? "map" : "base_link")
                    if mode.sendsPoints {
                        let classes = SceneFilter.classify(
                            cloud, crop: crop, exclusions: exclusions, robot: robot, robotPadding: Self.robotPadding
                        )
                        let kept = cloud.selecting(classes, equalTo: .kept)
                        if !kept.isEmpty {
                            let out3 = alignment.map { CloudRegistration.registering(kept, against: $0) }
                                ?? CloudRegistration.rotatedToROSAxes(kept)
                            out.points = (PLYCodec.encode(out3), out3.count)
                        }
                    }
                    if mode.sendsMesh, !mesh.isEmpty {
                        let classes = SceneFilter.classify(
                            mesh.centroids(), crop: crop, exclusions: exclusions, robot: robot,
                            robotPadding: Self.robotPadding
                        )
                        let kept = mesh.keepingTriangles(classes.map { $0 == .kept })
                        if !kept.isEmpty {
                            let out3 = alignment.map { CloudRegistration.registering(kept, against: $0) }
                                ?? CloudRegistration.rotatedToROSAxes(kept)
                            out.mesh = (MeshPLY.encode(out3), out3.triangleCount)
                        }
                    }
                    return out
                }.value
                guard let self else { return }
                defer { scanScene.isUploading = false }
                if prepared.points == nil, prepared.mesh == nil {
                    scanScene.status = mode.sendsMesh && mesh.isEmpty && !mode.sendsPoints
                        ? "No mesh yet — capture first."
                        : "Nothing left to upload — everything was filtered out (robot/boxes)."
                    return
                }
                let frameId = prepared.frameId
                var parts: [String] = []
                do {
                    if let points = prepared.points {
                        scanScene.status = "Uploading \(points.count) points…"
                        // Fixed name + `.replace`: the client holds the full accumulated,
                        // voxel-filtered state, so every upload fully replaces the latched topic.
                        let result = try await client.uploadCloud(points.data, frameId: frameId, name: "live_scan")
                        parts.append("\(result.points) points")
                    }
                    if let mesh = prepared.mesh {
                        scanScene.status = "Uploading mesh (\(mesh.triangles) triangles)…"
                        let result = try await client.uploadSceneMesh(mesh.data, frameId: frameId)
                        parts.append("\(result.triangles) triangles" + (result.applied ? "" : " (MoveIt not up yet)"))
                    }
                    let summary = parts.joined(separator: " + ")
                    scanScene.lastUploadSummary = "\(summary) (\(frameId))"
                    scanScene.status = frameId == "map"
                        ? "Uploaded \(summary), unregistered (no robot placed, frame \"map\")."
                        : "Uploaded \(summary)."
                } catch {
                    log.error("upload failed: \(String(describing: error), privacy: .public)")
                    let done = parts.isEmpty ? "" : " (sent: \(parts.joined(separator: " + ")))"
                    scanScene.status = "Upload failed: \(error)\(done)"
                }
            }
        }

        // MARK: Saved scenes (M5c)

        func refreshSceneList() {
            scanScene.scenes = sceneStore?.list() ?? []
        }

        /// Saves points + boxes in base_link, with the robot's link boxes at this moment (the
        /// scan-time pose), so the scene can be filtered and uploaded later without AR.
        private func saveScene(named name: String) {
            guard let store = sceneStore else {
                scanScene.status = "Can't save: the app's Documents folder isn't available."
                return
            }
            guard let alignment else {
                scanScene.status = "Place the robot first — scenes are saved relative to it."
                return
            }
            guard !scanCloud.isEmpty else {
                scanScene.status = "Nothing to save yet — capture a scan first."
                return
            }
            let cloud = scanCloud
            let robotNow = robotBoxes().map { StoredBox(world: $0, alignment: alignment) }
            let joints: [String: Double] = session.jointState.map { js in
                Dictionary(zip(js.name, js.position), uniquingKeysWith: { a, _ in a })
            } ?? [:]
            let manifest = SceneManifest(
                name: name, robotName: session.robotName, joints: joints, pointCount: cloud.count,
                cropEnabled: scanScene.cropEnabled, crop: crop,
                exclusions: scanScene.exclusionIDs.compactMap { exclusions[$0] },
                robotBoxes: robotNow, robotPadding: Self.robotPadding
            )
            scanScene.isWorkingOnScene = true
            scanScene.status = "Saving “\(name)”…"
            let processor = processor
            Task { [weak self] in
                let worldMesh = await processor.currentMesh()
                let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                    let points = CloudRegistration.registering(cloud, against: alignment)
                    let mesh = worldMesh.isEmpty ? nil : CloudRegistration.registering(worldMesh, against: alignment)
                    return Result { try store.save(SavedScene(manifest: manifest, points: points, mesh: mesh)) }
                }.value
                guard let self else { return }
                scanScene.isWorkingOnScene = false
                switch result {
                case .success:
                    scanScene.currentSceneName = name
                    scanScene.status = "Saved “\(name)” (\(cloud.count) points)."
                    refreshSceneList()
                case let .failure(error):
                    log.error("scene save failed: \(String(describing: error), privacy: .public)")
                    scanScene.status = "Couldn't save: \(error)"
                }
            }
        }

        /// Replaces the current scan (here, not on ROS) with a saved scene, placed against the
        /// current alignment; its boxes replace the current ones. Capturing continues on top.
        private func loadScene(_ id: String) {
            guard let store = sceneStore else { return }
            guard alignment != nil else {
                scanScene.status = "Place or restore the robot first — a scene is shown relative to it."
                return
            }
            scanScene.isWorkingOnScene = true
            scanScene.status = "Loading…"
            Task { [weak self] in
                let loaded = await Task.detached(priority: .userInitiated) { Result { try store.load(id) } }.value
                guard let self else { return }
                scanScene.isWorkingOnScene = false
                let scene: SavedScene
                switch loaded {
                case let .success(s): scene = s
                case let .failure(error):
                    scanScene.status = "Couldn't load: \(error)"
                    return
                }
                guard let alignment else { return } // robot removed meanwhile
                apply(scene, alignment: alignment)
            }
        }

        private func apply(_ scene: SavedScene, alignment: AlignmentTransform) {
            let m = scene.manifest
            resetLocalScan(resetReconstruction: true) // "load replaces": drop the current scan + mesh
            removeAllExclusions()
            crop = m.crop
            cropVisual?.update(crop)
            scanScene.cropEnabled = m.cropEnabled
            for box in m.exclusions {
                let id = nextExclusionID
                nextExclusionID += 1
                exclusions[id] = box
                if let root = alignmentRoot {
                    exclusionVisuals[id] = makeExclusionVisual(box, in: root)
                }
                scanScene.exclusionIDs.append(id)
            }
            refreshBoxSelection()
            sceneRobotBoxes = m.robotBoxes
            scanScene.currentSceneName = m.name
            var note = "scene “\(m.name)”"
            if let saved = m.robotName, let now = session.robotName, saved != now {
                note += " — saved with \(saved), current robot is \(now)"
            }
            lastCaptureNote = note
            let epoch = scanEpoch
            let processor = processor
            let points = scene.points
            let mesh = scene.mesh
            captureTask = Task { [weak self] in
                let (world, worldMesh) = await Task.detached(priority: .userInitiated) {
                    (
                        CloudRegistration.toWorld(points, from: alignment),
                        mesh?.mappingVertices { alignment.worldPoint(fromBaseLink: $0) }
                    )
                }.value
                let cloud = await processor.load(world, mesh: worldMesh, epoch: epoch)
                guard let self, epoch == scanEpoch else { return }
                scanCloud = cloud
                scanScene.pointCount = cloud.count
                updateCropSummary()
                refreshPreview()
            }
        }

        /// Sends a saved scene to ROS straight from disk: filtered in base_link with its own boxes
        /// and scan-time robot (plus the live robot if one is placed). No AR needed.
        private func uploadSavedScene(_ id: String) {
            guard let store = sceneStore else { return }
            guard let arBridgeURL = session.settings.arBridgeURL else {
                scanScene.status = "Connect to ar_bridge first (see connection settings)."
                return
            }
            let liveRobot = alignment.map { a in
                liveRobotBoxes().map { StoredBox(world: $0, alignment: a).orientedInBaseLink }
            } ?? []
            let client = ARBridgeClient(baseURL: arBridgeURL)
            let mode = scanScene.uploadMode
            scanScene.isWorkingOnScene = true
            scanScene.isUploading = true
            scanScene.status = "Preparing saved scene…"
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                let prepared = await Task.detached(priority: .userInitiated) { () -> Result<(PreparedUpload, String), Error> in
                    Result {
                        let scene = try store.load(id)
                        var out = PreparedUpload(frameId: "base_link")
                        if mode.sendsPoints {
                            let kept = scene.filteredForUpload(liveRobot: liveRobot)
                            if !kept.isEmpty { out.points = (PLYCodec.encode(kept), kept.count) }
                        }
                        if mode.sendsMesh, let kept = scene.filteredMeshForUpload(liveRobot: liveRobot) {
                            out.mesh = (MeshPLY.encode(kept), kept.triangleCount)
                        }
                        return (out, scene.manifest.name)
                    }
                }.value
                guard let self else { return }
                defer {
                    scanScene.isWorkingOnScene = false
                    scanScene.isUploading = false
                }
                switch prepared {
                case let .failure(error):
                    scanScene.status = "Couldn't read the scene: \(error)"
                case let .success((upload, name)):
                    guard upload.points != nil || upload.mesh != nil else {
                        scanScene.status = mode == .mesh
                            ? "“\(name)” has no mesh (saved before meshes, or none captured)."
                            : "“\(name)” has nothing left to upload after filtering."
                        return
                    }
                    var parts: [String] = []
                    do {
                        if let points = upload.points {
                            scanScene.status = "Uploading “\(name)” (\(points.count) points)…"
                            let result = try await client.uploadCloud(points.data, frameId: "base_link", name: "live_scan")
                            parts.append("\(result.points) points")
                        }
                        if let mesh = upload.mesh {
                            scanScene.status = "Uploading “\(name)” mesh (\(mesh.triangles) triangles)…"
                            let result = try await client.uploadSceneMesh(mesh.data, frameId: "base_link")
                            parts.append("\(result.triangles) triangles" + (result.applied ? "" : " (MoveIt not up yet)"))
                        }
                        let summary = parts.joined(separator: " + ")
                        scanScene.lastUploadSummary = "\(summary) (base_link)"
                        scanScene.status = "Uploaded “\(name)”: \(summary)."
                    } catch {
                        log.error("scene upload failed: \(String(describing: error), privacy: .public)")
                        scanScene.status = "Upload failed: \(error)"
                    }
                }
            }
        }

        // MARK: Scan filtering (M5b)

        /// One box per robot link: its meshes' bounds in the link's own frame, placed at the pose
        /// the AR robot has right now (the real robot doesn't move during a scan). Coarser than
        /// MoveIt's exact-mesh self-filter — it also takes a little around each link — which is
        /// fine: MoveIt still filters exactly, and this makes the phone's own output clean for
        /// any other planner.
        private func robotBoxes() -> [OrientedBox] {
            let fromScene = alignment.map { a in sceneRobotBoxes.map { $0.oriented(in: a) } } ?? []
            return fromScene + liveRobotBoxes()
        }

        /// The AR robot's link boxes at its current pose, in AR world.
        private func liveRobotBoxes() -> [OrientedBox] {
            guard let robot else { return [] }
            return robot.linkEntities.values.compactMap { link in
                let bounds = link.visualBounds(recursive: true, relativeTo: link)
                guard !bounds.isEmpty else { return nil }
                return OrientedBox(
                    worldFromBox: link.transformMatrix(relativeTo: nil), min: bounds.min, max: bounds.max
                )
            }
        }

        /// The crop box in AR world — only while enabled and a robot is placed (it's defined in
        /// base_link, so without an alignment there's nothing to place it against).
        private func cropBox() -> OrientedBox? {
            guard scanScene.cropEnabled, let alignment else { return nil }
            return crop.oriented(in: alignment)
        }

        private func exclusionBoxes() -> [OrientedBox] {
            guard let alignment else { return [] }
            return exclusions.values.map { $0.oriented(in: alignment) }
        }

        /// Re-classify and redraw — after a capture, a crop edit, and whenever the robot moves in
        /// the world (placed, re-placed, aligned), since that changes which points are "robot".
        /// Inputs are snapshotted here on the main thread (the boxes need RealityKit entities);
        /// classification and geometry run off it; stale results are dropped.
        private func refreshPreview() {
            guard !scanCloud.isEmpty, let arView else { return }
            previewGeneration += 1
            let generation = previewGeneration
            let epoch = scanEpoch
            let cloud = scanCloud
            let crop = cropBox()
            let exclusions = exclusionBoxes()
            let robot = robotBoxes()
            previewTask?.cancel()
            previewTask = Task { [weak self] in
                let geometry = await Task.detached(priority: .userInitiated) {
                    PreviewGeometry.compute(
                        cloud, crop: crop, exclusions: exclusions, robot: robot, robotPadding: Self.robotPadding
                    )
                }.value
                guard let self, generation == previewGeneration, epoch == scanEpoch else { return }
                // Fresh anchor on every redraw (device-confirmed fix — see `previewAnchor`).
                previewAnchor.map { arView.scene.removeAnchor($0) }
                let anchor = AnchorEntity(world: matrix_identity_float4x4)
                anchor.addChild(preview.root)
                arView.scene.addAnchor(anchor)
                previewAnchor = anchor
                await preview.show(geometry)
                guard generation == previewGeneration else { return }
                scanScene.keptCount = geometry.kept
                scanScene.robotCount = geometry.robot
                scanScene.croppedCount = geometry.cropped
                scanScene.excludedCount = geometry.excluded
                scanScene.status = "\(geometry.kept) to upload, \(geometry.robot) robot, "
                    + "\(geometry.excluded) excluded, \(geometry.cropped) cropped (\(lastCaptureNote))."
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
