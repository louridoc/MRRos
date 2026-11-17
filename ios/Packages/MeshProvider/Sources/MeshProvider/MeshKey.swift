import Foundation

/// Identity of a mesh as the URDF names it: `package://<package>/<path>`.
public struct MeshKey: Hashable, Sendable, CustomStringConvertible {
    public let package: String
    public let path: String

    public init(package: String, path: String) {
        self.package = package
        self.path = path
    }

    /// Parses `package://pkg/dir/file.dae`. Returns nil for other schemes.
    public init?(uri: String) {
        let prefix = "package://"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = uri.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let package = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        guard !package.isEmpty, !path.isEmpty, !path.contains("..") else { return nil }
        self.init(package: package, path: path)
    }

    public var uri: String {
        "package://\(package)/\(path)"
    }

    /// Path convention for tier 1/2 (bundled, cached-from-bundle-shaped-source): same tree,
    /// `.usdz` extension. These are produced offline by `tools/meshes/convert.py`.
    public var bundledRelativePath: String {
        "\(package)/\(stem).usdz"
    }

    /// Path convention for tier 3 (fetched from `ar_bridge`, which always serves OBJ — see
    /// `docs/protocols/ar_bridge_http.md`): same tree, `.obj` extension.
    public var remoteRelativePath: String {
        "\(package)/\(stem).obj"
    }

    private var stem: String {
        (path as NSString).deletingPathExtension
    }

    public var description: String {
        uri
    }
}

public enum MeshProviderError: Error, Equatable, Sendable {
    case invalidURI(String)
    case notFound(MeshKey)
    case manifestUnreadable(String)
}
