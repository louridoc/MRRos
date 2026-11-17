// Renders the REAL RobotModel/RealityKit pipeline on macOS — same RobotEntity, same mesh
// loader, same FrameConventions as the iPhone app — so mesh/FK orientation bugs can be found
// and fixed without a device round-trip. See tools/debug/render_robot.sh for usage.
//
// Scene (all in AR/world space, +Y up):
//   floor (gray plane at y=0) + a red/green/blue axis triad at the origin (0.3 m arms,
//   X=red, Y=green/up, Z=blue) so "which way is up" is never ambiguous in the screenshot.
//   The robot is placed with its baseFrame at the origin, directly on the floor.

import AlignmentKit
import AppKit
import ARBridgeTransport
import Foundation
import MeshProvider
import RealityKit
import RobotModel
import URDFKit

struct Args {
    var robot = "crx30ia"
    var positions: [String: Double] = [:]
    var out: URL
    var azimuthDeg: Double = 35
    var elevationDeg: Double = 25
    var distance: Double = 1.8
    var singleMesh: String?
    var extraRotDeg: Double = 0
    var meshTestRotDeg: Double = 0
    /// Overrides the fixture-directory convention — for a robot with no recorded fixture (e.g.
    /// one that's deliberately NOT in the bundle, to exercise MeshProvider's remote tier).
    var urdfPath: String?
    /// When set, MeshProvider gets a real `RemoteMeshSource` pointed at a live ar_bridge, e.g.
    /// `http://localhost:8765` — for testing M2b (a robot not in the bundle, fetched over HTTP)
    /// entirely on the Mac before ever touching the phone.
    var arBridgeURL: String?
}

func parseArgs() -> Args {
    var a = Args(out: URL(fileURLWithPath: "robotviz.png"))
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--robot": a.robot = it.next() ?? a.robot
        case "--out": a.out = URL(fileURLWithPath: it.next() ?? a.out.path)
        case "--azimuth": a.azimuthDeg = Double(it.next() ?? "") ?? a.azimuthDeg
        case "--elevation": a.elevationDeg = Double(it.next() ?? "") ?? a.elevationDeg
        case "--distance": a.distance = Double(it.next() ?? "") ?? a.distance
        case "--positions":
            // "J1=0.3,J2=-0.5" style, matching whatever joint names the URDF uses.
            for pair in (it.next() ?? "").split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = Double(kv[1]) {
                    a.positions[String(kv[0])] = v
                }
            }
        case "--single-mesh": a.singleMesh = it.next()
        case "--mesh-test-rot-deg": a.meshTestRotDeg = Double(it.next() ?? "") ?? 0
        case "--extra-rot-deg": a.extraRotDeg = Double(it.next() ?? "") ?? 0
        case "--urdf": a.urdfPath = it.next()
        case "--ar-bridge-url": a.arBridgeURL = it.next()
        default:
            FileHandle.standardError.write(Data("ignoring unknown arg: \(arg)\n".utf8))
        }
    }
    return a
}

let args = parseArgs()
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let meshesDir = repoRoot.appendingPathComponent("ios/MRRos/Meshes")

let urdfURL: URL = if let urdfPath = args.urdfPath {
    URL(fileURLWithPath: urdfPath)
} else {
    repoRoot.appendingPathComponent("ios/Packages/URDFKit/Tests/Fixtures/\(args.robot)/robot.urdf")
}

guard let urdfData = try? Data(contentsOf: urdfURL) else {
    fatalError("no URDF at \(urdfURL.path) — run tools/record-robot-fixtures.py first, or pass --urdf")
}

let robotModel = try! URDFParser.parse(urdfData)
print("robot: \(robotModel.name)  rootLink: \(robotModel.rootLink)  baseFrame: \(robotModel.baseFrame)")
print("actuated joints: \(robotModel.actuatedJointNames)")
print("positions: \(args.positions.isEmpty ? "(zero/home pose)" : "\(args.positions)")")

var meshSources: [any MeshSource] = [
    DirectoryMeshSource(name: "bundled", root: meshesDir),
    DirectoryMeshSource.cache(),
]
if let arBridgeURLString = args.arBridgeURL, let arBridgeURL = URL(string: arBridgeURLString) {
    print("ar_bridge: \(arBridgeURL) (remote mesh tier enabled)")
    meshSources.append(
        RemoteMeshSource(
            client: ARBridgeClient(baseURL: arBridgeURL),
            cacheRoot: DirectoryMeshSource.cache().root
        )
    )
}

let meshes = MeshProvider(sources: meshSources)

// MARK: - AppKit/RealityKit scaffolding (native macOS ARView, no AR session — see investigation

// notes in tools/meshes/usdz_convert.swift for why this exists at all).

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let size = CGSize(width: 1024, height: 1024)
let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
let arView = ARView(frame: NSRect(origin: .zero, size: size))
window.contentView = arView
window.setFrameOrigin(NSPoint(x: -4000, y: -4000)) // off (virtual) screen; still a real backing store
window.orderFrontRegardless()

arView.environment.background = .color(.init(white: 0.85, alpha: 1.0))

func deg2rad(_ d: Double) -> Float {
    Float(d * .pi / 180)
}

let camera = PerspectiveCamera()
camera.camera.fieldOfViewInDegrees = 42
let az = deg2rad(args.azimuthDeg), el = deg2rad(args.elevationDeg)
let camTarget = SIMD3<Float>(0, 0.4, 0) // a bit above the floor, roughly torso height
let camPos = camTarget + Float(args.distance) * SIMD3<Float>(
    cos(el) * sin(az), sin(el), cos(el) * cos(az)
)
camera.look(at: camTarget, from: camPos, relativeTo: nil)

let sun = DirectionalLight()
sun.light.intensity = 3000
sun.look(at: SIMD3<Float>(0, 0, 0), from: SIMD3<Float>(2, 3, 2), relativeTo: nil)
let fill = DirectionalLight()
fill.light.intensity = 1200
fill.look(at: SIMD3<Float>(0, 0, 0), from: SIMD3<Float>(-2, 1.5, -1), relativeTo: nil)

let floor = ModelEntity(
    mesh: .generatePlane(width: 3, depth: 3),
    materials: [SimpleMaterial(color: .init(white: 0.6, alpha: 1), roughness: 1, isMetallic: false)]
)

func axisArm(length: Float, color: NSColor) -> ModelEntity {
    let e = ModelEntity(
        mesh: .generateBox(width: 0.02, height: length, depth: 0.02),
        materials: [SimpleMaterial(color: color, roughness: 0.4, isMetallic: false)]
    )
    e.position = [0, length / 2, 0]
    return e
}

let originGizmo = Entity()
let xArm = axisArm(length: 0.3, color: .systemRed)
xArm.transform.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, -1]) // Y-arm rotated to +X
let yArm = axisArm(length: 0.3, color: .systemGreen) // already +Y
let zArm = axisArm(length: 0.3, color: .systemBlue)
zArm.transform.rotation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) // Y-arm rotated to +Z
originGizmo.addChild(xArm)
originGizmo.addChild(yArm)
originGizmo.addChild(zArm)

let anchor = AnchorEntity()
anchor.addChild(camera)
anchor.addChild(sun)
anchor.addChild(fill)
anchor.addChild(floor)
anchor.addChild(originGizmo)
arView.scene.addAnchor(anchor)

Task { @MainActor in
    if let singleMeshPath = args.singleMesh {
        // Bypass RobotEntity/FK entirely: load exactly one USDZ the way makeVisual() does, with
        // an extra, adjustable test rotation on top, so the mesh's OWN orientation can be judged
        // in isolation. (0, 90, 180, 270 about X are the only candidates worth comparing.)
        let loaded = try! await Entity(contentsOf: URL(fileURLWithPath: singleMeshPath))
        let wrapper = Entity()
        wrapper.transform.rotation = simd_quatf(angle: deg2rad(args.extraRotDeg), axis: [1, 0, 0])
        wrapper.addChild(loaded)
        anchor.addChild(wrapper)
        print("single-mesh mode: \(singleMeshPath), extra rot \(args.extraRotDeg) deg about X")
        for _ in 0 ..< 10 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        arView.snapshot(saveToHDR: false) { image in
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { exit(1) }
            try? png.write(to: args.out)
            print("wrote \(args.out.path)")
            exit(0)
        }
        return
    }

    let robotEntity = await RobotEntity(robot: robotModel, meshes: meshes)
    robotEntity.update(jointPositions: args.positions)
    anchor.addChild(robotEntity.root)
    if !robotEntity.placeholders.isEmpty {
        print("placeholders (mesh failed to load): \(robotEntity.placeholders)")
    }
    print("links placed: \(robotEntity.linkEntities.count)")

    if args.meshTestRotDeg != 0 {
        // Post-process every already-loaded visual mesh with an extra test rotation, without
        // touching production code or re-converting any USDZ — just to compare candidate fixes
        // on the FULL, asymmetric multi-link assembly (a single symmetric link, like the base,
        // can look "upright" at more than one rotation and is not conclusive on its own).
        var found = 0
        @MainActor func walk(_ e: Entity) {
            if e.name.hasPrefix("visual:") {
                found += 1
                let extra = simd_quatf(angle: deg2rad(args.meshTestRotDeg), axis: [1, 0, 0])
                e.transform.rotation = extra * e.transform.rotation
            }
            for c in e.children {
                walk(c)
            }
        }
        walk(robotEntity.root)
        print("applied extra \(args.meshTestRotDeg) deg (X) to \(found) visual meshes")
    }

    // Let a few frames render before snapshotting (first frame or two can be incomplete while
    // shaders/textures finish compiling).
    for _ in 0 ..< 10 {
        try? await Task.sleep(for: .milliseconds(100))
    }
    arView.snapshot(saveToHDR: false) { image in
        guard let image else {
            FileHandle.standardError.write(Data("snapshot returned nil\n".utf8))
            exit(1)
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
            exit(1)
        }
        try? png.write(to: args.out)
        print("wrote \(args.out.path)")
        exit(0)
    }
}

// A real run loop: Swift Concurrency's main executor and AppKit/CA rendering both need the main
// thread to actually be pumping, not blocked on a semaphore (that deadlocked the first version
// of this tool). The Task above calls exit() directly once the PNG is written.
app.run()
