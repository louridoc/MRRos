import Foundation

/// Where the rosbridge and ar_bridge live. Persisted in UserDefaults; never committed (lab IPs
/// vary). Both services run on the same host in practice (rosbridge from `ar_dev_bringup`,
/// ar_bridge alongside it) — see `docs/protocols/ar_bridge_http.md` for ar_bridge's default port.
public struct ConnectionSettings: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var arBridgePort: Int

    public init(host: String = "192.168.1.100", port: Int = 9090, arBridgePort: Int = 8765) {
        self.host = host
        self.port = port
        self.arBridgePort = arBridgePort
    }

    public var url: URL? {
        makeURL(scheme: "ws", port: port)
    }

    /// Base URL for `ar_bridge`'s HTTP surface (`GET <arBridgeURL>/v0/mesh?uri=...`, etc).
    public var arBridgeURL: URL? {
        makeURL(scheme: "http", port: arBridgePort)
    }

    private func makeURL(scheme: String, port: Int) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1 ... 65535).contains(port) else { return nil }
        return URL(string: "\(scheme)://\(trimmed):\(port)")
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
