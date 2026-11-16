import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md conventions).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "ROSMessages")

public enum ROSMessagesInfo {
    public static let name = "ROSMessages"
}
