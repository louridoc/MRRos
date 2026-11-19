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
    /// Breakdown of `pointCount` from the last classification: uploaded / robot / cropped out.
    var keptCount = 0
    var robotCount = 0
    var croppedCount = 0
    var isUploading = false
    var status = "Move around, then capture to add what the LiDAR has seen so far."
    var lastUploadSummary: String?

    // MARK: Crop box (M5b) — a box in base_link; only points inside it are uploaded.

    enum CropMode: String, CaseIterable, Identifiable {
        case move = "Move", size = "Size"
        var id: String {
            rawValue
        }
    }

    enum CropAxis: String, CaseIterable, Identifiable {
        case x = "X", y = "Y", z = "Z"
        var id: String {
            rawValue
        }
    }

    /// Crop applies (and is drawn) only while a robot is placed — it's defined in base_link.
    var cropEnabled = false
    /// Drag edits the box (axis-select-then-drag, like alignment). Mutually exclusive with
    /// `RobotScene.isAligning`; the UI enforces it.
    var isEditingCrop = false
    var cropMode: CropMode = .size
    var cropAxis: CropAxis = .x
    var cropSummary: String?
}
