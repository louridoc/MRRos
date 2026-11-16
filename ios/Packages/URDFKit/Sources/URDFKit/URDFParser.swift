import Foundation
import simd

public enum URDFParser {
    public static func parse(_ text: String) throws -> URDFRobot {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> URDFRobot {
        let root = try XMLDocument.parse(data)
        guard root.name == "robot" else { throw URDFError.notARobot(rootElement: root.name) }
        let name = root["name"] ?? ""

        // Top-level <material name><color rgba/></material> definitions, referenced by name.
        var materials: [String: Material] = [:]
        for m in root.all("material") {
            guard let mname = m["name"] else { continue }
            materials[mname] = try parseMaterial(m, named: materials)
        }

        var links: [String: Link] = [:]
        for l in root.all("link") {
            let lname = try attr(l, "name")
            guard links[lname] == nil else { throw URDFError.duplicateLink(lname) }
            links[lname] = try Link(
                name: lname,
                visuals: l.all("visual").map { try parseShape($0, materials: materials) },
                collisions: l.all("collision").map { try parseShape($0, materials: materials) }
            )
        }

        var joints: [Joint] = []
        var seenJoints = Set<String>()
        for j in root.all("joint") {
            let joint = try parseJoint(j)
            guard seenJoints.insert(joint.name).inserted else { throw URDFError.duplicateJoint(joint.name) }
            guard links[joint.parent] != nil else { throw URDFError.unknownLink(
                joint: joint.name,
                link: joint.parent
            ) }
            guard links[joint.child] != nil else { throw URDFError.unknownLink(
                joint: joint.name,
                link: joint.child
            ) }
            joints.append(joint)
        }

        // Tree validation: exactly one link without a parent, and every link reachable without cycles.
        var hasParent = Set<String>()
        var childJoints: [String: [Joint]] = [:]
        for j in joints {
            hasParent.insert(j.child)
            childJoints[j.parent, default: []].append(j)
        }
        let roots = links.keys.filter { !hasParent.contains($0) }.sorted()
        guard !roots.isEmpty else { throw URDFError.noRootLink }
        guard roots.count == 1, let rootLink = roots.first else { throw URDFError.multipleRootLinks(roots) }

        var visited = Set<String>()
        var stack = [rootLink]
        while let link = stack.popLast() {
            guard visited.insert(link).inserted else { throw URDFError.cycle(atLink: link) }
            for j in childJoints[link] ?? [] {
                stack.append(j.child)
            }
        }
        if let unreachable = links.keys.first(where: { !visited.contains($0) }) {
            // A link whose parent chain loops back without touching the root.
            throw URDFError.cycle(atLink: unreachable)
        }

        return URDFRobot(
            name: name,
            links: links,
            joints: joints,
            rootLink: rootLink,
            childJoints: childJoints,
            jointsByName: Dictionary(uniqueKeysWithValues: joints.map { ($0.name, $0) })
        )
    }

    // MARK: - Elements

    private static func parseJoint(_ j: XMLElement) throws -> Joint {
        let name = try attr(j, "name")
        let typeString = try attr(j, "type")
        guard let type = JointType(rawValue: typeString) else { throw URDFError.unknownJointType(typeString) }
        guard let parent = j.first("parent")?["link"] else {
            throw URDFError.missingAttribute(element: "joint/parent", attribute: "link")
        }
        guard let child = j.first("child")?["link"] else {
            throw URDFError.missingAttribute(element: "joint/child", attribute: "link")
        }
        let origin = try parseOrigin(j.first("origin"))
        var axis = SIMD3<Double>(1, 0, 0)
        if let a = j.first("axis") {
            axis = try vec3(a, "xyz") ?? axis
            let len = simd_length(axis)
            if len > 0 {
                axis /= len
            }
        }
        var limit: JointLimit?
        if let l = j.first("limit") {
            limit = JointLimit(
                lower: Double(l["lower"] ?? "") ?? 0,
                upper: Double(l["upper"] ?? "") ?? 0,
                effort: Double(l["effort"] ?? "") ?? 0,
                velocity: Double(l["velocity"] ?? "") ?? 0
            )
        }
        var mimic: Mimic?
        if let m = j.first("mimic") {
            mimic = try Mimic(
                joint: attr(m, "joint"),
                multiplier: Double(m["multiplier"] ?? "") ?? 1,
                offset: Double(m["offset"] ?? "") ?? 0
            )
        }
        return Joint(
            name: name, type: type, parent: parent, child: child,
            origin: origin, axis: axis, limit: limit, mimic: mimic
        )
    }

    private static func parseShape(_ s: XMLElement, materials: [String: Material]) throws -> Shape {
        guard let g = s.first("geometry"), let shape = g.children.first else {
            throw URDFError.missingAttribute(element: s.name, attribute: "geometry")
        }
        let geometry: Geometry
        switch shape.name {
        case "mesh":
            geometry = try .mesh(
                filename: attr(shape, "filename"),
                scale: vec3(shape, "scale") ?? SIMD3(1, 1, 1)
            )
        case "box":
            geometry = try .box(size: vec3(shape, "size") ?? .zero)
        case "cylinder":
            geometry = .cylinder(
                radius: Double(shape["radius"] ?? "") ?? 0,
                length: Double(shape["length"] ?? "") ?? 0
            )
        case "sphere":
            geometry = .sphere(radius: Double(shape["radius"] ?? "") ?? 0)
        default:
            throw URDFError.missingAttribute(element: "geometry", attribute: shape.name)
        }
        var material: Material?
        if let m = s.first("material") {
            material = try parseMaterial(m, named: materials)
        }
        return try Shape(
            name: s["name"],
            origin: parseOrigin(s.first("origin")),
            geometry: geometry,
            material: material
        )
    }

    private static func parseMaterial(_ m: XMLElement, named: [String: Material]) throws -> Material {
        var material = m["name"].flatMap { named[$0] } ?? Material(name: m["name"], rgba: nil, texture: nil)
        material.name = m["name"] ?? material.name
        if let c = m.first("color"), let rgba = try vec4(c, "rgba") {
            material.rgba = rgba
        }
        if let t = m.first("texture")?["filename"] {
            material.texture = t
        }
        return material
    }

    private static func parseOrigin(_ o: XMLElement?) throws -> Origin {
        guard let o else { return .identity }
        return try Origin(xyz: vec3(o, "xyz") ?? .zero, rpy: vec3(o, "rpy") ?? .zero)
    }

    // MARK: - Attributes

    private static func attr(_ e: XMLElement, _ name: String) throws -> String {
        guard let v = e[name] else { throw URDFError.missingAttribute(element: e.name, attribute: name) }
        return v
    }

    private static func numbers(_ e: XMLElement, _ name: String, count: Int) throws -> [Double]? {
        guard let raw = e[name] else { return nil }
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        let values = parts.compactMap(Double.init)
        guard values.count == count, parts.count == count else {
            throw URDFError.badVector(element: e.name, attribute: name, value: raw)
        }
        return values
    }

    private static func vec3(_ e: XMLElement, _ name: String) throws -> SIMD3<Double>? {
        try numbers(e, name, count: 3).map { SIMD3($0[0], $0[1], $0[2]) }
    }

    private static func vec4(_ e: XMLElement, _ name: String) throws -> SIMD4<Double>? {
        try numbers(e, name, count: 4).map { SIMD4($0[0], $0[1], $0[2], $0[3]) }
    }
}
