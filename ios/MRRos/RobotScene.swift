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
    /// Toggled directly by the UI (a mode, not a one-shot request): while true, a single drag
    /// gesture on the AR view nudges the placed robot's alignment along whichever axis
    /// `alignAxis` currently selects. See M4 in docs/PLAN.md.
    var isAligning = false

    enum AlignAxis: String, CaseIterable, Identifiable {
        case x = "X", z = "Z", yaw = "Rotate"
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
}
