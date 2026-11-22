import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "MeshProvider")

public enum MeshProviderInfo {
    public static let name = "MeshProvider"
}
