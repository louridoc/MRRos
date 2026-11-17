import ARBridgeTransport
import Foundation

/// Tier 3: fetches a mesh from `ar_bridge` over HTTP and caches it to disk (as OBJ, the only
/// format `ar_bridge` serves — see `docs/protocols/ar_bridge_http.md`) so later resolves of the
/// same key hit tier 2 (`DirectoryMeshSource.cache()`) without touching the network again.
///
/// This is the last tier by construction (`MeshProvider.standard(arBridge:)` only appends it
/// when a client is given), so letting it throw the rich `ARBridgeError` rather than returning
/// nil is more useful upstream: `RobotEntity` already catches broadly and falls back to a
/// placeholder regardless of which error reached it.
public struct RemoteMeshSource: MeshSource {
    public let name = "remote"
    private let client: ARBridgeClient
    private let cacheRoot: URL

    public init(client: ARBridgeClient, cacheRoot: URL) {
        self.client = client
        self.cacheRoot = cacheRoot
    }

    public func url(for key: MeshKey) async throws -> URL? {
        let fetched = try await client.fetchMesh(uri: key.uri)
        let dest = cacheRoot.appendingPathComponent(key.remoteRelativePath)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic: a concurrent resolve of the same key (two visuals sharing one mesh) never
        // observes a half-written file.
        let tmp = dest.appendingPathExtension("tmp-\(UUID().uuidString)")
        try fetched.data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        if FileManager.default.fileExists(atPath: tmp.path) {
            try? FileManager.default.removeItem(at: tmp) // replaceItemAt can leave it on some OS versions
        }
        log
            .info(
                "fetched \(key.uri, privacy: .public) (sha256 \(fetched.sourceSHA256.prefix(8), privacy: .public)…) → \(dest.lastPathComponent, privacy: .public)"
            )
        return dest
    }
}

public extension MeshProvider {
    /// Bundled → cache → remote (when `arBridge` is given; omit it before the app has connected).
    static func standard(arBridge: ARBridgeClient? = nil) -> MeshProvider {
        var sources: [any MeshSource] = [DirectoryMeshSource.bundled(), DirectoryMeshSource.cache()]
        if let arBridge {
            sources.append(RemoteMeshSource(client: arBridge, cacheRoot: DirectoryMeshSource.cache().root))
        }
        return MeshProvider(sources: sources)
    }
}
