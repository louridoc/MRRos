import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md conventions).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "RobotModel")

public enum RobotModelInfo {
    public static let name = "RobotModel"
}
