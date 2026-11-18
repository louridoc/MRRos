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
    }

    /// Set by the UI; consumed (reset to nil) by the AR coordinator.
    var request: Request?
    var isPlaced = false
    var isBuilding = false
    /// Toggled directly by the UI (a mode, not a one-shot request): while true, drag/rotate
    /// gestures on the AR view nudge the placed robot's alignment, and it renders translucent
    /// so it's visually obvious you're comparing against the camera passthrough, not just
    /// looking at an opaque model. See M4 in docs/PLAN.md.
    var isAligning = false
    var status = "Connect and receive a robot description, then place it."
    var placeholders: [String] = []
    var placedRobotName: String?
}
