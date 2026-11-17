// Batch DAE/STL/OBJ → USDZ converter using macOS SceneKit (no third-party deps).
//
// COLLADA (.dae) up-axis bug: loading a DAE through SceneKit and writing it straight to USDZ does
// not round-trip at net-identity through RealityKit's loader (the real runtime consumer) — the
// asset comes out rotated. OBJ/STL sources have no up-axis metadata and already round-trip
// clean (verified empirically), so this is specific to COLLADA's up-axis handling somewhere in
// the SceneKit-write / RealityKit-read path; the exact mechanism did not fully pin down
// analytically (two candidate derivations each looked internally consistent and were each wrong
// by a multiple of 90°). What's actually load-bearing is the EMPIRICAL fix below, validated the
// only way that is conclusive for this bug: rendering the full, assembled, multi-link CRX-30iA
// (not a single, often axis-symmetric part — the base alone looked "plausibly upright" at a
// WRONG candidate rotation and nearly caused a second wrong fix) standing correctly upright, via
// `tools/debug/RobotViz` — a macOS RealityKit visualizer running this project's real RobotModel/
// RobotEntity code, not a reimplementation. (Investigated 2026-11-16, corrected the same night
// after the first fix — which tested correct in isolation — still rendered wrong on a real
// multi-link robot.)
//
// RobotModel's RobotEntity composes meshes directly into its Z-up (ROS/URDF) link tree and
// applies the ROS→AR rotation exactly once, at the top (`AlignmentKit.FrameConventions`). That
// means every mesh we hand it must load, net, as if raw-authored Z-up data had been rotated
// +90° about X (not 0°, not 180° — both were tried and visibly wrong on the full assembly). Fix:
// for `.dae` sources only, wrap the scene's top-level children in one extra node rotated 90°
// about X before writing. The wrap must NOT be applied to OBJ/STL sources — doing so introduces
// the very bug it fixes (confirmed: this file's own regression check, Check 2 below, failed
// loudly on the OBJ/trimesh-fallback path the one time it was tried).
//
// If this ever needs re-deriving: change the angle in `tools/debug/RobotViz`'s
// `--mesh-test-rot-deg` (0/90/180/270, same-axis rotations so they're exhaustive) against the
// FULL robot, not a single mesh, before touching this file.
//
// Usage: swift tools/meshes/usdz_convert.swift jobs.json
//   jobs.json: [{"src": "/abs/in.dae", "dst": "/abs/out.usdz"}, ...]
//   stdout:    one JSON object per line: {"dst", "ok", "tris", "bbox", "wrapped", "error"?}

import Foundation
import RealityKit
import SceneKit
import simd

struct Job: Decodable {
    let src: String
    let dst: String
}

struct Result: Encodable {
    let dst: String
    let ok: Bool
    var tris = 0
    var bbox: [Double] = []
    var wrapped = false
    var error: String?
}

/// Name of the corrective wrapper node, so the regression check below can find it by identity
/// rather than by guessing which node "looks like" the fix.
private let axisFixNodeName = "MRRosAxisFix"

func needsAxisFix(_ src: URL) -> Bool {
    src.pathExtension.lowercased() == "dae"
}

func convert(_ job: Job) -> Result {
    let src = URL(fileURLWithPath: job.src)
    let dst = URL(fileURLWithPath: job.dst)
    do {
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let scene = try SCNScene(url: src, options: [.checkConsistency: true])
        var tris = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            if let g = node.geometry {
                tris += g.elements.reduce(0) { $0 + $1.primitiveCount }
            }
        }
        guard tris > 0 else { return Result(dst: job.dst, ok: false, error: "no triangles") }

        let wrap = needsAxisFix(src)
        if wrap {
            let fix = SCNNode()
            fix.name = axisFixNodeName
            fix.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            for child in scene.rootNode.childNodes {
                child.removeFromParentNode()
                fix.addChildNode(child)
            }
            scene.rootNode.addChildNode(fix)
        }
        // Bounds captured AFTER the wrap, so Check 1 below compares against exactly what gets
        // written (a pre-wrap capture would legitimately "drift" by the wrap rotation itself).
        let (mn, mx) = scene.rootNode.boundingBox

        try? FileManager.default.removeItem(at: dst)
        guard scene.write(to: dst, options: nil, delegate: nil, progressHandler: nil) else {
            return Result(dst: job.dst, ok: false, error: "SceneKit write failed")
        }

        // Check 1 (corruption): SceneKit must be able to re-read its own file with the same bounds.
        // This is self-consistent and does NOT exercise the up-axis bug (see header) — it only
        // catches gross write/read corruption.
        let back = try SCNScene(url: dst)
        let (bmn, bmx) = back.rootNode.boundingBox
        let drift = max(
            abs(bmn.x - mn.x), abs(bmn.y - mn.y), abs(bmn.z - mn.z),
            abs(bmx.x - mx.x), abs(bmx.y - mx.y), abs(bmx.z - mx.z)
        )
        guard drift < 1e-3 else {
            try? FileManager.default.removeItem(at: dst)
            return Result(dst: job.dst, ok: false, error: "bounds drifted by \(drift) (SceneKit re-read)")
        }

        // Check 2 (regression): load with RealityKit — the real runtime consumer — and confirm our
        // wrapper node is present with exactly the rotation we wrote, whenever we applied the fix.
        // This is a mechanical "did the fix actually run" check (catches e.g. an extension-matching
        // bug silently skipping the wrap), not a re-proof of the physics derivation above.
        if wrap {
            let loaded = try Entity.load(contentsOf: dst)
            guard let fixEntity = findNamed(loaded, axisFixNodeName) else {
                try? FileManager.default.removeItem(at: dst)
                return Result(dst: job.dst, ok: false, error: "axis-fix node missing after RealityKit load")
            }
            let q = fixEntity.transform.rotation
            let expected = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            // simd_quatf.angle is canonicalized to [0, π], so "near zero" is the only passing case.
            let residual = (q.inverse * expected).angle
            guard residual < 1e-3 else {
                try? FileManager.default.removeItem(at: dst)
                return Result(dst: job.dst, ok: false, error: "axis-fix rotation wrong after reload: \(q)")
            }
        }

        return Result(
            dst: job.dst, ok: true, tris: tris,
            bbox: [mn.x, mn.y, mn.z, mx.x, mx.y, mx.z].map(Double.init),
            wrapped: wrap
        )
    } catch {
        return Result(dst: job.dst, ok: false, error: "\(error)")
    }
}

/// Depth-first search by exact entity/node name, as RealityKit exposes it after loading a USDZ.
func findNamed(_ entity: Entity, _ name: String) -> Entity? {
    if entity.name == name {
        return entity
    }
    for child in entity.children {
        if let found = findNamed(child, name) {
            return found
        }
    }
    return nil
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: usdz_convert.swift jobs.json\n".utf8))
    exit(2)
}

let jobs = try JSONDecoder().decode(
    [Job].self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
)
let encoder = JSONEncoder()
var failures = 0
for job in jobs {
    let r = convert(job)
    if !r.ok {
        failures += 1
    }
    try print(String(decoding: encoder.encode(r), as: UTF8.self))
}

exit(failures == 0 ? 0 : 1)
