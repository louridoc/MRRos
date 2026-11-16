import Foundation
import os
import ROSMessages
import URDFKit

/// Turns `/joint_states` messages into the joint-position dictionary the URDF FK expects.
///
/// Handles the real-world mess: messages that carry only a subset of joints (several
/// publishers), joints the URDF does not know, prefixed names (`ur_shoulder_pan_joint` vs
/// `shoulder_pan_joint`), and out-of-limit values. Keeps the last known value for every joint
/// so partial messages never reset the arm.
public struct JointStateMapper: Sendable {
    public struct Report: Sendable, Equatable {
        public var applied = 0
        public var unknown: [String] = []
        public var clamped: [String] = []
    }

    public let robot: URDFRobot
    public var clampToLimits: Bool
    public private(set) var positions: [String: Double]
    private let actuated: Set<String>
    /// suffix → URDF joint name, for prefix-tolerant matching (only unambiguous suffixes).
    private let bySuffix: [String: String]
    private static let log = Logger(subsystem: "io.github.louridoc.mrros", category: "RobotModel")

    public init(robot: URDFRobot, clampToLimits: Bool = true) {
        self.robot = robot
        self.clampToLimits = clampToLimits
        let names = robot.actuatedJointNames
        actuated = Set(names)
        positions = Dictionary(uniqueKeysWithValues: names.map { ($0, 0.0) })
        var suffix: [String: String?] = [:]
        for n in names {
            // every suffix starting at an underscore boundary, e.g. "a_b_c" → "b_c", "c"
            var idx = n.startIndex
            while let us = n[idx...].firstIndex(of: "_") {
                let s = String(n[n.index(after: us)...])
                suffix[s] = suffix[s] == nil ? n : .some(nil) // nil = ambiguous
                idx = n.index(after: us)
            }
        }
        bySuffix = suffix.compactMapValues { $0 }
    }

    /// Apply a message; returns what happened (for diagnostics, not for control flow).
    @discardableResult
    public mutating func apply(_ msg: SensorMsgs.JointState) -> Report {
        var report = Report()
        for (i, name) in msg.name.enumerated() where i < msg.position.count {
            guard let joint = resolve(name) else {
                report.unknown.append(name)
                continue
            }
            var q = msg.position[i]
            if clampToLimits, let limit = robot.jointsByName[joint]?.limit,
               robot.jointsByName[joint]?.type == .revolute || robot.jointsByName[joint]?.type == .prismatic,
               limit.upper > limit.lower, q < limit.lower || q > limit.upper
            {
                q = min(max(q, limit.lower), limit.upper)
                report.clamped.append(joint)
            }
            positions[joint] = q
            report.applied += 1
        }
        if !report.unknown.isEmpty {
            Self.log
                .debug(
                    "ignored joints not in URDF: \(report.unknown.joined(separator: ","), privacy: .public)"
                )
        }
        return report
    }

    /// Exact name first, then a prefix-tolerant match in either direction.
    func resolve(_ name: String) -> String? {
        if actuated.contains(name) {
            return name
        }
        if let j = bySuffix[name] {
            return j
        } // message "shoulder_pan_joint" ↔ URDF "ur_shoulder_pan_joint"
        // message "ur_shoulder_pan_joint" ↔ URDF "shoulder_pan_joint"
        var idx = name.startIndex
        while let us = name[idx...].firstIndex(of: "_") {
            let s = String(name[name.index(after: us)...])
            if actuated.contains(s) {
                return s
            }
            idx = name.index(after: us)
        }
        return nil
    }
}
