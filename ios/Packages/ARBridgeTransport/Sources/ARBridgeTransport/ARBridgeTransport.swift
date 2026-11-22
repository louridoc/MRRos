import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ARBridgeTransport")

public enum ARBridgeTransportInfo {
    public static let name = "ARBridgeTransport"
}
