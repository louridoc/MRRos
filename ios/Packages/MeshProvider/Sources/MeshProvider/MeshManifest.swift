import Foundation

/// `meshes.json` written by `tools/meshes/convert.py`.
public struct MeshManifest: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let uri: String
        /// Relative to the manifest's directory.
        public let file: String
        /// SHA-256 of the *source* mesh (DAE/STL), the cross-tier cache key.
        public let sha256: String
        public let bytes: Int
        public let tris: Int
        /// min xyz, max xyz in the mesh's own (ROS/URDF) coordinates and units.
        public let bbox: [Double]
        public let source: String
    }

    public let version: Int
    public let generated: String
    public let robots: [String]
    public let entries: [Entry]

    private var byURI: [String: Entry] {
        Dictionary(
            entries.map { ($0.uri, $0) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    public func entry(for key: MeshKey) -> Entry? {
        byURI[key.uri]
    }

    public static func load(from url: URL) throws -> MeshManifest {
        do {
            return try JSONDecoder().decode(MeshManifest.self, from: Data(contentsOf: url))
        } catch {
            throw MeshProviderError.manifestUnreadable("\(url.lastPathComponent): \(error)")
        }
    }
}
