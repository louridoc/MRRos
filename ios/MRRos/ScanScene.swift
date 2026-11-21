import Foundation
import Observation
import SceneLibrary

/// UI-facing state of the environment scan: capture/clear/upload requests from the sheet,
/// results from the AR coordinator. Mirrors `RobotScene`'s request/consume pattern.
@MainActor
@Observable
final class ScanScene {
    enum Request: Equatable {
        case capture
        case clear
        case upload
        /// New exclusion box where the screen centre hits a surface, then select it.
        case addExclusion
        /// Delete the selected exclusion box.
        case deleteSelected
        /// Save the current scan, boxes and scan-time robot pose as a scene with this name.
        case saveScene(name: String)
        /// Replace the current scan with a saved scene (needs a placed robot).
        case loadScene(id: String)
        /// Send a saved scene to ROS without loading it into AR.
        case uploadScene(id: String)
    }

    // MARK: Saved scenes (M5c)

    /// Rows for the Scenes sheet; refreshed by the coordinator after save/rename/delete.
    var scenes: [SceneSummary] = []
    var showScenes = false
    /// Name of the scene currently loaded (or last saved), for the status line and save default.
    var currentSceneName: String?
    /// Busy flag for save/load/upload-from-list, so the sheet can disable its buttons.
    var isWorkingOnScene = false

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

    // MARK: Scan boxes (M5b) — all defined in base_link, so they move with the robot.
    // One crop box (keep only what's inside) + any number of exclusion boxes (drop what's inside).

    enum BoxEditMode: String, CaseIterable, Identifiable {
        case move = "Move", size = "Size", rotate = "Rotate"
        var id: String {
            rawValue
        }
    }

    enum EditAxis: String, CaseIterable, Identifiable {
        case x = "X", y = "Y", z = "Z"
        var id: String {
            rawValue
        }
    }

    enum EditTarget: Hashable {
        case crop
        case exclusion(Int)
    }

    /// Crop applies (and is drawn) only while a robot is placed — it's defined in base_link.
    var cropEnabled = false
    /// Drag edits the selected box (axis-select-then-drag, like alignment). Mutually exclusive
    /// with `RobotScene.isAligning`; the UI enforces it.
    var isEditingBoxes = false
    var editTarget: EditTarget = .crop
    /// Rotate is about the box's vertical axis, exclusion boxes only.
    var editMode: BoxEditMode = .size
    var editAxis: EditAxis = .x
    /// Stable IDs of the exclusion boxes, in creation order (for the selector chips).
    var exclusionIDs: [Int] = []
    var cropSummary: String?
    var excludedCount = 0
}
