import Foundation
import os

/// One tier of mesh lookup. Returns `nil` when it does not have the mesh (next tier is tried)
/// and throws only for real failures.
public protocol MeshSource: Sendable {
    var name: String { get }
    func url(for key: MeshKey) async throws -> URL?
}

/// Tier 1 (bundled) and tier 2 (cache) share one shape: a directory with `meshes.json` and
/// `<package>/<path>.usdz` files. A missing manifest means an empty tier, not an error.
public struct DirectoryMeshSource: MeshSource {
    public let name: String
    public let root: URL
    public let manifest: MeshManifest?

    public init(name: String, root: URL) {
        self.name = name
        self.root = root
        manifest = try? MeshManifest.load(from: root.appendingPathComponent("meshes.json"))
    }

    public func url(for key: MeshKey) async throws -> URL? {
        let rel = manifest?.entry(for: key)?.file ?? key.bundledRelativePath
        let url = root.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public extension DirectoryMeshSource {
    /// Meshes shipped inside the app (`ios/MRRos/Meshes`, a folder reference in the Xcode project).
    static func bundled(_ bundle: Bundle = .main, subdirectory: String = "Meshes") -> DirectoryMeshSource {
        let root = bundle.resourceURL?
            .appendingPathComponent(subdirectory) ?? URL(fileURLWithPath: "/nonexistent")
        return DirectoryMeshSource(name: "bundled", root: root)
    }

    /// Meshes fetched earlier from `ar_bridge` (tier 3 writes here).
    static func cache() -> DirectoryMeshSource {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DirectoryMeshSource(name: "cache", root: base.appendingPathComponent("Meshes"))
    }
}

/// Resolves URDF mesh URIs to local, loadable files by asking each tier in order. Results are
/// memoised per key for the provider's lifetime.
public actor MeshProvider {
    private let sources: [any MeshSource]
    private var resolved: [MeshKey: URL] = [:]
    private let log = Logger(subsystem: "io.github.louridoc.mrros", category: "MeshProvider")

    public init(sources: [any MeshSource]) {
        self.sources = sources
    }

    /// Bundled → cache (→ remote, added in M2b).
    public static func standard() -> MeshProvider {
        MeshProvider(sources: [DirectoryMeshSource.bundled(), DirectoryMeshSource.cache()])
    }

    public func resolve(_ uri: String) async throws -> URL {
        guard let key = MeshKey(uri: uri) else { throw MeshProviderError.invalidURI(uri) }
        return try await resolve(key)
    }

    public func resolve(_ key: MeshKey) async throws -> URL {
        if let hit = resolved[key] {
            return hit
        }
        for source in sources {
            if let url = try await source.url(for: key) {
                log.debug("\(key.uri, privacy: .public) ← \(source.name, privacy: .public)")
                resolved[key] = url
                return url
            }
        }
        log.warning("no source has \(key.uri, privacy: .public)")
        throw MeshProviderError.notFound(key)
    }
}
