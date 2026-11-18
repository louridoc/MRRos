import AlignmentKit
import Foundation
import Observation

/// UI-facing state of the AR robot: placement requests from buttons, results from the AR
/// coordinator. Kept in the app target because it is pure view-model glue.
@MainActor
@Observable
final class RobotScene {
    enum Request: Equatable {
        case place
        case remove
        /// Re-run the AR session from the saved `ARWorldMap` and re-place the robot once ARKit
        /// relocalizes (M4b).
        case restoreSaved
        case forgetSaved
    }

    /// Set by the UI; consumed (reset to nil) by the AR coordinator.
    var request: Request?
    var isPlaced = false
    var isBuilding = false
    /// Toggled directly by the UI (a mode, not a one-shot request): while true, a single drag
    /// gesture on the AR view nudges the placed robot's alignment along whichever axis
    /// `alignAxis` currently selects. See M4 in docs/PLAN.md.
    var isAligning = false

    /// Degrees of freedom in `base_link` (ROS convention, matching the red/green/blue triad
    /// drawn at the base): translate along base X, Y or Z (up/down — e.g. a robot on a pedestal
    /// or a floor plane ARKit estimated slightly off), or rotate about base Z.
    enum AlignAxis: String, CaseIterable, Identifiable {
        case x = "X", y = "Y", z = "Z", yaw = "Rotate Z"
        var id: String {
            rawValue
        }
    }

    /// Which degree of freedom the alignment drag currently moves — axis-select-then-drag,
    /// not a free 2D/3D gesture. Chosen deliberately after a free-drag gizmo (raycasting the
    /// floor under the touch) proved unreliable in practice: see the M4 findings in
    /// docs/testing.md for the full story.
    var alignAxis: AlignAxis = .x
    var status = "Connect and receive a robot description, then place it."
    var placeholders: [String] = []
    var placedRobotName: String?
    /// The saved alignment slot, if any — set by the coordinator from `AlignmentStore`.
    var savedAlignment: SavedAlignmentInfo?
    /// True between `.restoreSaved` and ARKit relocalizing (or the user placing manually instead).
    var isRestoring = false
}
