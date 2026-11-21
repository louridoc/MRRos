import AlignmentKit
import ARBridgeTransport
import Foundation
import LiDARScan
@testable import SceneLibrary
import simd
import Testing

private func manifest(
    name: String = "bench", createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    cropEnabled: Bool = false, exclusions: [BaseLinkBox] = [], robotBoxes: [StoredBox] = []
) -> SceneManifest {
    SceneManifest(
        name: name, createdAt: createdAt, robotName: "ur10e", joints: ["shoulder_pan_joint": 0.5],
        pointCount: 0, cropEnabled: cropEnabled,
        crop: BaseLinkBox(center: SIMD3(0, 0, 0.5), half: SIMD3(1, 1, 0.5)),
        exclusions: exclusions, robotBoxes: robotBoxes, robotPadding: 0
    )
}

struct SceneFilteringTests {
    /// Points along base_link X; z = 0.5 so they sit inside the crop's height band.
    private let points = PointCloud(
        x: [0.1, 0.6, 2.5, 0.9], y: [0, 0, 0, 0], z: [0.5, 0.5, 0.5, 0.5]
    )

    @Test func scanTimeRobotBoxesExclusionsAndCropAllApplyInBaseLink() {
        let robot = StoredBox(
            baseLinkFromBox: matrix_identity_float4x4, min: SIMD3(-0.2, -0.2, 0), max: SIMD3(0.2, 0.2, 1)
        )
        let exclusion = BaseLinkBox(center: SIMD3(0.9, 0, 0.5), half: SIMD3(repeating: 0.1))
        let scene = SavedScene(
            manifest: manifest(cropEnabled: true, exclusions: [exclusion], robotBoxes: [robot]),
            points: points
        )
        #expect(scene.classify() == [.robot, .kept, .outsideCrop, .excluded])
        #expect(scene.filteredForUpload().x == [0.6])
    }

    @Test func liveRobotIsRemovedTooWhenGiven() {
        let scene = SavedScene(manifest: manifest(), points: points)
        let live = OrientedBox(
            worldFromBox: matrix_identity_float4x4,
            min: SIMD3(0.5, -1, 0),
            max: SIMD3(0.7, 1, 1)
        )
        #expect(scene.classify(liveRobot: [live]) == [.kept, .robot, .kept, .kept])
    }

    @Test func storedBoxRoundTripsThroughBaseLink() {
        // A world box re-expressed in base_link and placed back must contain the same points.
        let alignment = AlignmentTransform(position: SIMD3(0.4, 0, -1.2), yaw: 1.1)
        var rot = simd_float4x4(simd_quatf(angle: 0.5, axis: simd_normalize(SIMD3(1, 1, 0))))
        rot.columns.3 = SIMD4(0.3, 0.1, -1.0, 1)
        let world = OrientedBox(worldFromBox: rot, min: SIMD3(-0.1, -0.2, -0.3), max: SIMD3(0.1, 0.2, 0.3))
        let stored = StoredBox(world: world, alignment: alignment)
        let samples: [SIMD3<Float>] = [SIMD3(0.3, 0.1, -1.0), SIMD3(0.35, 0.2, -1.1), SIMD3(0.6, 0.1, -1.0)]
        for p in samples {
            #expect(stored.oriented(in: alignment).contains(p) == world.contains(p))
            #expect(stored.orientedInBaseLink.contains(alignment.baseLinkPoint(fromWorld: p)) == world
                .contains(p))
        }
    }

    @Test func pointCountFollowsThePoints() {
        #expect(SavedScene(manifest: manifest(), points: points).manifest.pointCount == 4)
    }
}

struct SceneStoreTests {
    private func tempStore() -> SceneStore {
        SceneStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("scenes-\(UUID().uuidString)", isDirectory: true))
    }

    private let cloud = PointCloud(x: [1, 2], y: [3, 4], z: [5, 6])

    @Test func saveLoadRoundTrip() throws {
        let store = tempStore()
        let robot = StoredBox(baseLinkFromBox: matrix_identity_float4x4, min: .zero, max: SIMD3(1, 1, 1))
        let scene = SavedScene(
            manifest: manifest(
                exclusions: [BaseLinkBox(center: .zero, half: SIMD3(1, 1, 1), yaw: 0.3)],
                robotBoxes: [robot]
            ),
            points: cloud
        )
        let id = try store.save(scene)
        #expect(try store.load(id) == scene)
        #expect(!id.contains(":"))
    }

    @Test func listIsNewestFirstAndSkipsFoldersWithoutAManifest() throws {
        let store = tempStore()
        try store.save(SavedScene(
            manifest: manifest(name: "old", createdAt: Date(timeIntervalSince1970: 1)),
            points: cloud
        ))
        try store.save(SavedScene(
            manifest: manifest(name: "new", createdAt: Date(timeIntervalSince1970: 2)),
            points: cloud
        ))
        try FileManager.default.createDirectory(
            at: store.directory.appendingPathComponent("stray"), withIntermediateDirectories: true
        )
        #expect(store.list().map(\.manifest.name) == ["new", "old"])
    }

    @Test func sameNameScenesDoNotCollide() throws {
        let store = tempStore()
        let a = try store.save(SavedScene(manifest: manifest(), points: cloud))
        let b = try store.save(SavedScene(manifest: manifest(), points: cloud))
        #expect(a != b)
        #expect(store.list().count == 2)
    }

    @Test func renameAndDelete() throws {
        let store = tempStore()
        let id = try store.save(SavedScene(manifest: manifest(), points: cloud))
        try store.rename(id, to: "cell 2")
        #expect(try store.load(id).manifest.name == "cell 2")
        try store.delete(id)
        #expect(store.list().isEmpty)
        #expect(throws: SceneStoreError.notFound(id)) { try store.load(id) }
    }

    @Test func missingPointsIsCorrupt() throws {
        let store = tempStore()
        let id = try store.save(SavedScene(manifest: manifest(), points: cloud))
        try FileManager.default.removeItem(at: store.folder(id).appendingPathComponent(SceneStore.pointsFile))
        #expect(throws: SceneStoreError.self) { try store.load(id) }
    }

    @Test func newerFormatVersionIsRejected() throws {
        var m = manifest()
        m.version = SceneManifest.currentVersion + 1
        let data = try SceneStore.encodeManifest(m)
        #expect(throws: SceneStoreError.unsupportedVersion(m.version)) { try SceneStore.decodeManifest(data) }
    }
}

/// Writes the cross-language fixture ar_bridge's tests read (ros2_ws/src/ar_bridge/test/fixtures/
/// scene_v1): a scene with a rotated robot box (exercises the column-major matrix), padding, a
/// yawed exclusion and a crop, plus `expected_kept.ply` = what Swift's filter keeps. Python must
/// reproduce it exactly. Runs only when MRROS_SCENE_FIXTURE_DIR is set:
///   MRROS_SCENE_FIXTURE_DIR=$PWD/ros2_ws/src/ar_bridge/test/fixtures \
///     swift test --package-path ios/Packages/SceneLibrary --filter writeCrossLanguageFixture
struct CrossLanguageFixture {
    @Test func writeCrossLanguageFixture() throws {
        guard let dir = ProcessInfo.processInfo.environment["MRROS_SCENE_FIXTURE_DIR"] else { return }
        var xs = [Float](), ys = [Float](), zs = [Float]()
        for i in -10 ... 10 {
            for j in -10 ... 10 {
                for k in 0 ... 6 {
                    xs.append(Float(i) * 0.15)
                    ys.append(Float(j) * 0.15)
                    zs.append(Float(k) * 0.2)
                }
            }
        }
        var linkPose = simd_float4x4(simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3(0.3, 1, 0.2))))
        linkPose.columns.3 = SIMD4(0.2, -0.1, 0.4, 1)
        let manifest = SceneManifest(
            name: "fixture", createdAt: Date(timeIntervalSince1970: 1_800_000_000), robotName: "ur10e",
            joints: ["shoulder_pan_joint": 0.25], pointCount: 0, cropEnabled: true,
            crop: BaseLinkBox(center: SIMD3(0.1, 0, 0.6), half: SIMD3(1.1, 0.9, 0.55), yaw: 0.3),
            exclusions: [BaseLinkBox(center: SIMD3(-0.6, 0.5, 0.4), half: SIMD3(0.3, 0.2, 0.3), yaw: 0.8)],
            robotBoxes: [StoredBox(baseLinkFromBox: linkPose, min: SIMD3(-0.1, -0.3, -0.1), max: SIMD3(0.1, 0.3, 0.2))],
            robotPadding: 0.03
        )
        let scene = SavedScene(manifest: manifest, points: PointCloud(x: xs, y: ys, z: zs))
        let folder = URL(fileURLWithPath: dir).appendingPathComponent("scene_v1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PLYCodec.encode(scene.points).write(to: folder.appendingPathComponent(SceneStore.pointsFile))
        try SceneStore.encodeManifest(scene.manifest).write(to: folder.appendingPathComponent(SceneStore.manifestFile))
        let kept = scene.filteredForUpload()
        try PLYCodec.encode(kept).write(to: folder.appendingPathComponent("expected_kept.ply"))
        let classes = scene.classify()
        print("fixture: \(scene.points.count) points, kept \(kept.count), robot \(classes.filter { $0 == .robot }.count), excluded \(classes.filter { $0 == .excluded }.count)")
    }
}

struct SceneTransferTests {
    private let base = URL(string: "http://mock:8765")!

    private func store() -> SceneStore {
        SceneStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("scenes-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func pushSendsPointsBeforeTheManifest() async throws {
        let local = store()
        let id = try local.save(SavedScene(manifest: manifest(), points: PointCloud(x: [1], y: [2], z: [3])))
        let mock = MockHTTPTransport()
        await mock.respond(whenURLContains: "/v0/scenes/", with: HTTPResponse(statusCode: 200, data: Data("{}".utf8), headers: [:]))
        try await SceneTransfer.push(id, from: local, to: ARBridgeClient(baseURL: base, transport: mock))
        let paths = await mock.puts.map(\.url.lastPathComponent)
        #expect(paths == [SceneStore.pointsFile, SceneStore.manifestFile])
    }

    @Test func pullRoundTripsAPushedScene() async throws {
        let source = store()
        let scene = SavedScene(manifest: manifest(name: "cell"), points: PointCloud(x: [1, 2], y: [3, 4], z: [5, 6]))
        let id = try source.save(scene)
        let (m, p) = try source.files(id)
        let mock = MockHTTPTransport()
        await mock.respond(whenURLContains: "/\(SceneStore.manifestFile)", with: HTTPResponse(statusCode: 200, data: m, headers: [:]))
        await mock.respond(whenURLContains: "/\(SceneStore.pointsFile)", with: HTTPResponse(statusCode: 200, data: p, headers: [:]))
        let dest = store()
        try await SceneTransfer.pull(id, from: ARBridgeClient(baseURL: base, transport: mock), into: dest)
        #expect(try dest.load(id) == scene)
    }

    @Test func aCorruptDownloadIsNotImported() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(whenURLContains: "/\(SceneStore.manifestFile)", with: HTTPResponse(statusCode: 200, data: try SceneStore.encodeManifest(manifest()), headers: [:]))
        await mock.respond(whenURLContains: "/\(SceneStore.pointsFile)", with: HTTPResponse(statusCode: 200, data: Data("junk".utf8), headers: [:]))
        let dest = store()
        await #expect(throws: SceneStoreError.self) {
            try await SceneTransfer.pull("x", from: ARBridgeClient(baseURL: base, transport: mock), into: dest)
        }
        #expect(dest.list().isEmpty)
    }
}
