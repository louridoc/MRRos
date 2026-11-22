import AlignmentKit
import Foundation
import LiDARScan
import simd

/// A box with any rotation, stored in `base_link` — a robot link's bounds at scan time.
/// (`BaseLinkBox` only turns about Z; link boxes are arbitrarily oriented.)
public struct StoredBox: Sendable, Equatable, Codable {
    /// Column-major 4×4, the box's frame in base_link.
    public var baseLinkFromBox: [Float]
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(baseLinkFromBox: simd_float4x4, min: SIMD3<Float>, max: SIMD3<Float>) {
        let c = baseLinkFromBox.columns
        self.baseLinkFromBox = [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        self.min = min
        self.max = max
    }

    /// An AR-world box (e.g. a link's bounds from RealityKit) re-expressed in base_link.
    public init(world box: OrientedBox, alignment: AlignmentTransform) {
        self.init(
            baseLinkFromBox: alignment.worldFromBaseLink.inverse * box.boxFromWorld.inverse,
            min: box.min, max: box.max
        )
    }

    public var matrix: simd_float4x4 {
        guard baseLinkFromBox.count == 16 else { return matrix_identity_float4x4 }
        let m = baseLinkFromBox
        return simd_float4x4(
            SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
            SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])
        )
    }

    /// In base_link itself (for filtering a base_link cloud).
    public var orientedInBaseLink: OrientedBox {
        OrientedBox(worldFromBox: matrix, min: min, max: max)
    }

    /// Placed in AR world for an alignment (for the preview after loading).
    public func oriented(in alignment: AlignmentTransform) -> OrientedBox {
        OrientedBox(worldFromBox: alignment.worldFromBaseLink * matrix, min: min, max: max)
    }
}

/// Everything about a saved scene except its points — small, so a list can show many.
/// Stored as `scene.json` beside `points.ply`; see docs/protocols/scene_format.md.
public struct SceneManifest: Sendable, Equatable, Codable {
    public static let formatName = "mrros.scene"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var name: String
    public var createdAt: Date
    /// `robot_description`'s robot name when saved — loading warns on a mismatch.
    public var robotName: String?
    /// Joint angles when saved (the real robot's pose in the scan). Informational; the filter
    /// uses `robotBoxes`, which already encode that pose.
    public var joints: [String: Double]
    /// Always "base_link": points and boxes are robot-relative, so a scene survives re-placing.
    public var frameId: String
    public var pointCount: Int
    /// Triangles in the optional `mesh.ply`; nil = no mesh (older scenes, or none captured).
    public var triangleCount: Int?
    public var cropEnabled: Bool
    public var crop: BaseLinkBox
    public var exclusions: [BaseLinkBox]
    /// The robot's link boxes at scan time. Removed from the scan on every later filter, so the
    /// real robot's old pose can't come back as a phantom obstacle after it has moved.
    public var robotBoxes: [StoredBox]
    public var robotPadding: Float

    public init(
        name: String, createdAt: Date = Date(), robotName: String?, joints: [String: Double],
        pointCount: Int, cropEnabled: Bool, crop: BaseLinkBox, exclusions: [BaseLinkBox],
        robotBoxes: [StoredBox], robotPadding: Float
    ) {
        format = Self.formatName
        version = Self.currentVersion
        frameId = "base_link"
        self.name = name
        self.createdAt = createdAt
        self.robotName = robotName
        self.joints = joints
        self.pointCount = pointCount
        self.cropEnabled = cropEnabled
        self.crop = crop
        self.exclusions = exclusions
        self.robotBoxes = robotBoxes
        self.robotPadding = robotPadding
    }
}

/// A scene: manifest + its raw (unfiltered) points, and optionally the room mesh, in base_link.
public struct SavedScene: Sendable, Equatable {
    public var manifest: SceneManifest
    public var points: PointCloud
    public var mesh: ScanMesh?

    public init(manifest: SceneManifest, points: PointCloud, mesh: ScanMesh? = nil) {
        var manifest = manifest
        let mesh = mesh?.isEmpty == true ? nil : mesh
        manifest.pointCount = points.count
        manifest.triangleCount = mesh?.triangleCount
        self.manifest = manifest
        self.points = points
        self.mesh = mesh
    }

    /// Per-point classes in base_link with the scene's own boxes — what an upload straight from
    /// the list sends (`.kept` only). `liveRobot` adds the robot's current boxes (in base_link)
    /// when known: points where the robot is NOW can't be obstacles either.
    public func classify(liveRobot: [OrientedBox] = []) -> [PointClass] {
        classify(points, liveRobot: liveRobot)
    }

    /// The mesh to upload (triangles kept by their centroid, same boxes), still in base_link.
    public func filteredMeshForUpload(liveRobot: [OrientedBox] = []) -> ScanMesh? {
        guard let mesh else { return nil }
        let classes = classify(mesh.centroids(), liveRobot: liveRobot)
        let kept = mesh.keepingTriangles(classes.map { $0 == .kept })
        return kept.isEmpty ? nil : kept
    }

    private func classify(_ cloud: PointCloud, liveRobot: [OrientedBox]) -> [PointClass] {
        SceneFilter.classify(
            cloud,
            crop: manifest.cropEnabled ? manifest.crop.orientedInBaseLink : nil,
            exclusions: manifest.exclusions.map(\.orientedInBaseLink),
            robot: manifest.robotBoxes.map(\.orientedInBaseLink) + liveRobot,
            robotPadding: manifest.robotPadding
        )
    }

    /// The points to upload, still in base_link.
    public func filteredForUpload(liveRobot: [OrientedBox] = []) -> PointCloud {
        points.selecting(classify(liveRobot: liveRobot), equalTo: .kept)
    }
}
