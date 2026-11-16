import Foundation

/// Where the rosbridge lives. Persisted in UserDefaults; never committed (lab IPs vary).
public struct ConnectionSettings: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String = "192.168.1.100", port: Int = 9090) {
        self.host = host
        self.port = port
    }

    public var url: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1 ... 65535).contains(port) else { return nil }
        return URL(string: "ws://\(trimmed):\(port)")
    }

    static let defaultsKey = "io.github.louridoc.mrros.connection"

    public static func load(from defaults: UserDefaults = .standard) -> ConnectionSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(ConnectionSettings.self, from: data)
        else { return ConnectionSettings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
