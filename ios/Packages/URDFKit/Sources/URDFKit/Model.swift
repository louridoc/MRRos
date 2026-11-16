import Foundation
import simd

public enum URDFError: Error, Equatable, Sendable {
    case malformedXML(line: Int, reason: String)
    case notARobot(rootElement: String)
    case missingAttribute(element: String, attribute: String)
    case badVector(element: String, attribute: String, value: String)
    case unknownJointType(String)
    case duplicateLink(String)
    case duplicateJoint(String)
    case unknownLink(joint: String, link: String)
    case noRootLink
    case multipleRootLinks([String])
    case cycle(atLink: String)
}

/// `<origin xyz rpy>` — URDF RPY is fixed-axis XYZ: R = Rz(yaw) · Ry(pitch) · Rx(roll).
public struct Origin: Sendable, Equatable {
    public var xyz: SIMD3<Double>
    public var rpy: SIMD3<Double>

    public init(xyz: SIMD3<Double> = .zero, rpy: SIMD3<Double> = .zero) {
        self.xyz = xyz
        self.rpy = rpy
    }

    public static let identity = Origin()

    public var rotation: simd_quatd {
        let r = simd_quatd(angle: rpy.x, axis: SIMD3(1, 0, 0))
        let p = simd_quatd(angle: rpy.y, axis: SIMD3(0, 1, 0))
        let y = simd_quatd(angle: rpy.z, axis: SIMD3(0, 0, 1))
        return y * p * r
    }

    public var matrix: simd_double4x4 {
        var m = simd_double4x4(rotation)
        m.columns.3 = SIMD4(xyz, 1)
        return m
    }
}

public enum Geometry: Sendable, Equatable {
    /// `filename` is kept verbatim (`package://…` or `file://…`); `scale` defaults to 1.
    case mesh(filename: String, scale: SIMD3<Double>)
    case box(size: SIMD3<Double>)
    case cylinder(radius: Double, length: Double)
    case sphere(radius: Double)
}

public struct Material: Sendable, Equatable {
    public var name: String?
    /// RGBA in 0…1, if a `<color>` was given (inline or via a top-level `<material name>`).
    public var rgba: SIMD4<Double>?
    public var texture: String?
}

/// `<visual>` or `<collision>`.
public struct Shape: Sendable, Equatable {
    public var name: String?
    public var origin: Origin
    public var geometry: Geometry
    public var material: Material?
}

public struct Link: Sendable, Equatable {
    public var name: String
    public var visuals: [Shape]
    public var collisions: [Shape]
}

public enum JointType: String, Sendable {
    case revolute, continuous, prismatic, fixed, floating, planar

    /// Joints that take a scalar position from `/joint_states`.
    public var isActuated: Bool {
        switch self {
        case .revolute, .continuous, .prismatic: true
        case .fixed, .floating, .planar: false
        }
    }
}

public struct JointLimit: Sendable, Equatable {
    public var lower: Double
    public var upper: Double
    public var effort: Double
    public var velocity: Double
}

public struct Mimic: Sendable, Equatable {
    public var joint: String
    public var multiplier: Double
    public var offset: Double
}

public struct Joint: Sendable, Equatable {
    public var name: String
    public var type: JointType
    public var parent: String
    public var child: String
    public var origin: Origin
    /// Unit axis in the joint frame (defaults to +X per the URDF spec).
    public var axis: SIMD3<Double>
    public var limit: JointLimit?
    public var mimic: Mimic?

    /// Transform from parent link frame to child link frame at joint position `q`.
    public func transform(position q: Double) -> simd_double4x4 {
        let fixed = origin.matrix
        switch type {
        case .revolute, .continuous:
            return fixed * simd_double4x4(simd_quatd(angle: q, axis: axis))
        case .prismatic:
            var t = matrix_identity_double4x4
            t.columns.3 = SIMD4(axis * q, 1)
            return fixed * t
        case .fixed, .floating, .planar:
            return fixed
        }
    }
}

/// A parsed URDF with its kinematic tree validated (single root, no cycles, all links known).
public struct URDFRobot: Sendable {
    public let name: String
    public let links: [String: Link]
    /// Document order.
    public let joints: [Joint]
    public let rootLink: String
    /// Child joints per parent link, document order.
    public let childJoints: [String: [Joint]]
    public let jointsByName: [String: Joint]

    /// Actuated joints in document order (the ones `/joint_states` should carry).
    public var actuatedJointNames: [String] {
        joints.filter { $0.type.isActuated && $0.mimic == nil }.map(\.name)
    }

    /// Mesh filenames referenced by visuals (deduplicated, document order).
    public var visualMeshFilenames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in linkNamesInTreeOrder() {
            for shape in links[name]?.visuals ?? [] {
                if case let .mesh(filename, _) = shape.geometry, seen.insert(filename).inserted {
                    out.append(filename)
                }
            }
        }
        return out
    }

    /// Links from the root downwards, depth-first, children in document order.
    public func linkNamesInTreeOrder() -> [String] {
        var out: [String] = []
        func visit(_ link: String) {
            out.append(link)
            for j in childJoints[link] ?? [] {
                visit(j.child)
            }
        }
        visit(rootLink)
        return out
    }
}
