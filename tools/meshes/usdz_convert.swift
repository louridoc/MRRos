// Batch DAE/STL/OBJ → USDZ converter using macOS SceneKit (no third-party deps).
// Coordinates are preserved as authored (no up-axis or unit conversion); URDF `scale` is applied
// at placement time by RobotModel, never baked here.
//
// Usage: swift tools/meshes/usdz_convert.swift jobs.json
//   jobs.json: [{"src": "/abs/in.dae", "dst": "/abs/out.usdz"}, ...]
//   stdout:    one JSON object per line: {"dst", "ok", "tris", "bbox": [minx,miny,minz,maxx,maxy,maxz], "error"?}

import Foundation
import SceneKit

struct Job: Decodable {
    let src: String
    let dst: String
}

struct Result: Encodable {
    let dst: String
    let ok: Bool
    var tris = 0
    var bbox: [Double] = []
    var error: String?
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
        let (mn, mx) = scene.rootNode.boundingBox
        try? FileManager.default.removeItem(at: dst)
        guard scene.write(to: dst, options: nil, delegate: nil, progressHandler: nil) else {
            return Result(dst: job.dst, ok: false, error: "SceneKit write failed")
        }
        // Round-trip check: the exported file must load and keep its bounds.
        let back = try SCNScene(url: dst)
        let (bmn, bmx) = back.rootNode.boundingBox
        let drift = max(
            abs(bmn.x - mn.x),
            abs(bmn.y - mn.y),
            abs(bmn.z - mn.z),
            abs(bmx.x - mx.x),
            abs(bmx.y - mx.y),
            abs(bmx.z - mx.z)
        )
        guard drift < 1e-3
        else { return Result(dst: job.dst, ok: false, error: "bounds drifted by \(drift)") }
        return Result(
            dst: job.dst, ok: true, tris: tris,
            bbox: [mn.x, mn.y, mn.z, mx.x, mx.y, mx.z].map(Double.init)
        )
    } catch {
        return Result(dst: job.dst, ok: false, error: "\(error)")
    }
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
