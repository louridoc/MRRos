import ARBridgeTransport
import Foundation

/// Moves scenes between the phone's `SceneStore` and ar_bridge's library: same id, same two files.
public enum SceneTransfer {
    /// Phone → ROS machine. Points first, manifest last, so ar_bridge never lists a half-sent scene.
    public static func push(_ id: String, from store: SceneStore, to client: ARBridgeClient) async throws {
        let files = try store.files(id)
        try await client.putSceneFile(id: id, file: SceneStore.pointsFile, data: files.points)
        if let mesh = files.mesh {
            try await client.putSceneFile(id: id, file: SceneStore.meshFile, data: mesh)
        }
        try await client.putSceneFile(id: id, file: SceneStore.manifestFile, data: files.manifest)
    }

    /// ROS machine → phone, validated before it's written (see `SceneStore.importFiles`).
    public static func pull(_ id: String, from client: ARBridgeClient, into store: SceneStore) async throws {
        let manifest = try await client.sceneFile(id: id, file: SceneStore.manifestFile)
        let points = try await client.sceneFile(id: id, file: SceneStore.pointsFile)
        var mesh: Data?
        if (try? SceneStore.decodeManifest(manifest))?.triangleCount != nil {
            mesh = try await client.sceneFile(id: id, file: SceneStore.meshFile)
        }
        try store.importFiles(id: id, SceneStore.Files(manifest: manifest, points: points, mesh: mesh))
    }
}
