import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md conventions).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ROSBridgeClient")

public enum ROSBridgeClientInfo {
    public static let name = "ROSBridgeClient"
}
