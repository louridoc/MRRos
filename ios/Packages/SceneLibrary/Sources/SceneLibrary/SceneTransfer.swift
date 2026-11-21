import ARBridgeTransport
import Foundation

/// Moves scenes between the phone's `SceneStore` and ar_bridge's library: same id, same two files.
public enum SceneTransfer {
    /// Phone → ROS machine. Points first, manifest last, so ar_bridge never lists a half-sent scene.
    public static func push(_ id: String, from store: SceneStore, to client: ARBridgeClient) async throws {
        let (manifest, points) = try store.files(id)
        try await client.putSceneFile(id: id, file: SceneStore.pointsFile, data: points)
        try await client.putSceneFile(id: id, file: SceneStore.manifestFile, data: manifest)
    }

    /// ROS machine → phone, validated before it's written (see `SceneStore.importFiles`).
    public static func pull(_ id: String, from client: ARBridgeClient, into store: SceneStore) async throws {
        let manifest = try await client.sceneFile(id: id, file: SceneStore.manifestFile)
        let points = try await client.sceneFile(id: id, file: SceneStore.pointsFile)
        try store.importFiles(id: id, manifest: manifest, points: points)
    }
}
