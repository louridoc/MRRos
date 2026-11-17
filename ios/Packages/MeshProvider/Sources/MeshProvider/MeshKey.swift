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
        guard uri.hasPrefix(uri), uri.hasPrefix(prefix) else { return nil }
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

    /// Path inside the bundle / cache: same tree, `.usdz` extension.
    public var bundledRelativePath: String {
        let stem = (path as NSString).deletingPathExtension
        return "\(package)/\(stem).usdz"
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
