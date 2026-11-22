import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "LiDARScan")

public enum LiDARScanInfo {
    public static let name = "LiDARScan"
}
