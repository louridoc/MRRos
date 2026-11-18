import Foundation

/// What the UI needs to offer a restore, without loading the (multi-MB) map.
public struct SavedAlignmentInfo: Codable, Sendable, Equatable {
    public let robotName: String?
    public let savedAt: Date

    public init(robotName: String?, savedAt: Date) {
        self.robotName = robotName
        self.savedAt = savedAt
    }
}

public enum AlignmentStoreError: Error, Equatable, Sendable {
    /// Metadata exists but the map blob is missing or unreadable — a half-written or tampered slot.
    case corrupt(String)
}

/// One saved-alignment slot on disk: an opaque archived `ARWorldMap` (which itself carries the
/// `anchorName` anchor at the aligned `base_link` pose) plus small JSON metadata.
///
/// Platform-neutral on purpose — the map is just `Data` here; archiving/unarchiving the actual
/// `ARWorldMap` happens in the app target — so the slot logic is testable on macOS.
/// Write order is map first, metadata last (both atomic), so metadata's presence means the slot
/// is complete.
public struct AlignmentStore: Sendable {
    /// Name of the `ARAnchor` placed at the aligned `base_link` pose before the map is captured.
    public static let anchorName = "mrros.base_link"

    public let directory: URL
    private var mapURL: URL {
        directory.appendingPathComponent("worldmap.arexperience")
    }

    private var infoURL: URL {
        directory.appendingPathComponent("alignment.json")
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/MRRos/alignment` — survives app restarts, not user-visible in Files.
    public static func standard() throws -> AlignmentStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return AlignmentStore(directory: support.appendingPathComponent("MRRos/alignment", isDirectory: true))
    }

    public func save(worldMap: Data, info: SavedAlignmentInfo) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try worldMap.write(to: mapURL, options: .atomic)
        try Self.encoder.encode(info).write(to: infoURL, options: .atomic)
    }

    /// `nil` when nothing is saved. Unreadable metadata is treated as "nothing saved" rather than
    /// an error so a bad file can't wedge the UI; a missing map behind valid metadata is `.corrupt`.
    public func info() -> SavedAlignmentInfo? {
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? Self.decoder.decode(SavedAlignmentInfo.self, from: data)
    }

    public func load() throws -> (worldMap: Data, info: SavedAlignmentInfo)? {
        guard let info = info() else { return nil }
        guard let map = try? Data(contentsOf: mapURL), !map.isEmpty else {
            throw AlignmentStoreError.corrupt("saved alignment has metadata but no world map")
        }
        return (map, info)
    }

    public func clear() throws {
        for url in [infoURL, mapURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
