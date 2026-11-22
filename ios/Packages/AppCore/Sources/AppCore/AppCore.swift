import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "AppCore")

public enum AppCoreInfo {
    public static let name = "AppCore"
}
