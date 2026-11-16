import Foundation
#if os(iOS)
import ARKit
#endif

/// Static facts about the running app, used by the status strip and diagnostics export.
public enum AppInfo {
    public static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Whether this device can do LiDAR scene reconstruction (required from M3 on).
    public static var hasLiDAR: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #else
        return false
        #endif
    }

    public static var lidarSupportDescription: String {
        hasLiDAR ? "LiDAR" : "no LiDAR"
    }
}
