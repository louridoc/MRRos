import Foundation
import Observation

/// UI-facing state of the environment scan: capture/clear/upload requests from the sheet,
/// results from the AR coordinator. Mirrors `RobotScene`'s request/consume pattern.
@MainActor
@Observable
final class ScanScene {
    enum Request: Equatable {
        case capture
        case clear
        case upload
    }

    /// Set by the UI; consumed (reset to nil) by the AR coordinator.
    var request: Request?
    var pointCount = 0
    var isUploading = false
    var status = "Move around, then capture to add what the LiDAR has seen so far."
    var lastUploadSummary: String?
}
