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
    var status = "Connect and receive a robot description, then place it."
    var placeholders: [String] = []
    var placedRobotName: String?
}
