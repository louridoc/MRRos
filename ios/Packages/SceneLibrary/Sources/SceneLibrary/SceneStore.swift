import Foundation
import LiDARScan

public enum SceneStoreError: Error, Equatable, Sendable {
    case notFound(String)
    /// A manifest without readable points, or points that don't decode.
    case corrupt(String)
    /// Written by a newer app/ar_bridge than this one understands.
    case unsupportedVersion(Int)
}

/// One row of the scenes list.
public struct SceneSummary: Sendable, Equatable, Identifiable {
    /// The scene's folder name. Stable; also what ar_bridge's library uses.
    public let id: String
    public let manifest: SceneManifest
}

/// Scenes on disk: one folder per scene holding `scene.json` + `points.ply`. In the app this is
/// `Documents/Scenes`, visible in the Files app — a scene folder AirDropped or copied in shows up
/// in the list as is. Points are written before the manifest (both atomic), so a folder with a
/// manifest is complete; folders without a readable manifest are ignored.
public struct SceneStore: Sendable {
    public static let manifestFile = "scene.json"
    public static let pointsFile = "points.ply"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Documents/Scenes`.
    public static func standard() throws -> SceneStore {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return SceneStore(directory: documents.appendingPathComponent("Scenes", isDirectory: true))
    }

    /// Newest first.
    public func list() -> [SceneSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { folder in
            guard let manifest = try? readManifest(folder) else { return nil }
            return SceneSummary(id: folder.lastPathComponent, manifest: manifest)
        }
        .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Saves as a new scene; returns its id. The folder name is readable (name + date) plus a
    /// short random suffix, so two scenes with the same name never collide.
    @discardableResult
    public func save(_ scene: SavedScene) throws -> String {
        let id = Self.makeID(name: scene.manifest.name, date: scene.manifest.createdAt)
        try write(scene, to: folder(id))
        return id
    }

    public func load(_ id: String) throws -> SavedScene {
        let folder = folder(id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.manifestFile).path)
        else {
            throw SceneStoreError.notFound(id)
        }
        let manifest = try readManifest(folder)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.pointsFile)) else {
            throw SceneStoreError.corrupt("\(id): no \(Self.pointsFile)")
        }
        do {
            return try SavedScene(manifest: manifest, points: PLYCodec.decode(data))
        } catch {
            throw SceneStoreError.corrupt("\(id): \(error)")
        }
    }

    public func rename(_ id: String, to name: String) throws {
        let folder = folder(id)
        var manifest = try readManifest(folder)
        manifest.name = name
        try Self.encoder.encode(manifest).write(
            to: folder.appendingPathComponent(Self.manifestFile),
            options: .atomic
        )
    }

    public func delete(_ id: String) throws {
        let folder = folder(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw SceneStoreError.notFound(id) }
        try FileManager.default.removeItem(at: folder)
    }

    /// The scene's folder, for sharing it (AirDrop, Files).
    public func folder(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    /// Writes a scene received as its two files (pulled from ar_bridge) under `id`, after checking
    /// both decode — a bad download never becomes a listed scene. Same id = same scene: replaced.
    public func importFiles(id: String, manifest: Data, points: Data) throws {
        _ = try Self.decodeManifest(manifest)
        do {
            _ = try PLYCodec.decode(points)
        } catch {
            throw SceneStoreError.corrupt("\(id): \(error)")
        }
        let folder = folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try points.write(to: folder.appendingPathComponent(Self.pointsFile), options: .atomic)
        try manifest.write(to: folder.appendingPathComponent(Self.manifestFile), options: .atomic)
    }

    /// The scene's two files as stored, for pushing to ar_bridge.
    public func files(_ id: String) throws -> (manifest: Data, points: Data) {
        let folder = folder(id)
        guard let manifest = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestFile)) else {
            throw SceneStoreError.notFound(id)
        }
        guard let points = try? Data(contentsOf: folder.appendingPathComponent(Self.pointsFile)) else {
            throw SceneStoreError.corrupt("\(id): no \(Self.pointsFile)")
        }
        return (manifest, points)
    }

    // MARK: Encoding (shared with the ar_bridge transfer, which sends the same two files)

    public static func encodeManifest(_ manifest: SceneManifest) throws -> Data {
        try encoder.encode(manifest)
    }

    public static func decodeManifest(_ data: Data) throws -> SceneManifest {
        let manifest = try decoder.decode(SceneManifest.self, from: data)
        guard manifest.format == SceneManifest.formatName else {
            throw SceneStoreError.corrupt("not an \(SceneManifest.formatName) manifest")
        }
        guard manifest.version <= SceneManifest.currentVersion else {
            throw SceneStoreError.unsupportedVersion(manifest.version)
        }
        return manifest
    }

    // MARK: Private

    private func write(_ scene: SavedScene, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PLYCodec.encode(scene.points).write(
            to: folder.appendingPathComponent(Self.pointsFile),
            options: .atomic
        )
        try Self.encodeManifest(scene.manifest).write(
            to: folder.appendingPathComponent(Self.manifestFile), options: .atomic
        )
    }

    private func readManifest(_ folder: URL) throws -> SceneManifest {
        try Self.decodeManifest(Data(contentsOf: folder.appendingPathComponent(Self.manifestFile)))
    }

    static func makeID(name: String, date: Date) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = String(
            name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let stamp = idDateFormatter.string(from: date)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(slug.isEmpty ? "scene" : String(slug))_\(stamp)_\(suffix)"
    }

    /// `20261121-174600` in UTC: sortable, and no `:` (not allowed in folder names everywhere).
    private static let idDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
