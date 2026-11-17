import Foundation

/// Exponential smoothing of joint targets so a 10–30 Hz `/joint_states` stream renders without
/// visible stepping at 60 fps. Continuous joints are smoothed along the shortest arc.
public struct JointSmoother: Sendable {
    /// Time constant: after `tau` the remaining error is 37 %. 0 disables smoothing.
    public var tau: TimeInterval
    public private(set) var current: [String: Double] = [:]
    private var targets: [String: Double] = [:]
    private var wraps: Set<String>

    public init(tau: TimeInterval = 0.06, wrapAroundJoints: Set<String> = []) {
        self.tau = tau
        wraps = wrapAroundJoints
    }

    public mutating func setTargets(_ t: [String: Double]) {
        targets = t
        for (k, v) in t where current[k] == nil {
            current[k] = v
        } // first value: no lag
    }

    /// Advance by `dt` seconds; returns the smoothed positions.
    @discardableResult
    public mutating func step(dt: TimeInterval) -> [String: Double] {
        guard tau > 0, dt > 0 else {
            current = targets
            return current
        }
        let alpha = 1 - exp(-dt / tau)
        for (k, target) in targets {
            let c = current[k] ?? target
            var delta = target - c
            if wraps.contains(k) {
                delta = (delta + .pi).truncatingRemainder(dividingBy: 2 * .pi) - .pi
                if delta < -.pi {
                    delta += 2 * .pi
                }
            }
            let next = c + delta * alpha
            current[k] = abs(target - next) < 1e-6 ? target : next
        }
        return current
    }
}
