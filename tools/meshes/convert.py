#!/usr/bin/env python3
"""Build the bundled mesh set: every *visual* mesh referenced by the priority robots' URDF
fixtures, converted to USDZ with Apple's SceneKit, plus a manifest the app uses for lookup.

Output (committed):
  ios/MRRos/Meshes/<package>/<relative path>.usdz
  ios/MRRos/Meshes/meshes.json   — {"version", "generated", "robots", "entries": [...]}
    entry: {uri, file, sha256, bytes, tris, bbox, source, via}

Usage: tools/meshes/convert.py [robot ...]     (default: the five priority robots)
Source packages are resolved from the Jazzy env share dir and the built ros2_ws install.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES = os.path.join(ROOT, "ios", "Packages", "URDFKit", "Tests", "Fixtures")
OUT = os.path.join(ROOT, "ios", "MRRos", "Meshes")
CONVERTER = os.path.join(ROOT, "tools", "meshes", "usdz_convert.swift")
SHARE_DIRS = [
    os.path.join(ROOT, "ros2_ws", "install", "jazzy", "fanuc_crx_description", "share"),
    os.path.expanduser("~/micromamba/envs/ros_jazzy/share"),
]
ROBOTS = sys.argv[1:] or ["crx30ia", "crx20ial", "ur30", "ur20", "ur10e"]


def resolve(pkg: str, rel: str) -> str:
    for d in SHARE_DIRS:
        p = os.path.join(d, pkg, rel)
        if os.path.exists(p):
            return p
    raise FileNotFoundError(f"package://{pkg}/{rel}")


def source_version(path: str) -> str:
    """Git describe of the external checkout, or the conda package version, for the manifest."""
    ext = os.path.join(ROOT, "ros2_ws", "src", "external", "fanuc_description")
    if "fanuc" in path and os.path.isdir(ext):
        rev = subprocess.run(
            ["git", "-C", ext, "rev-parse", "--short", "HEAD"], capture_output=True, text=True
        )
        return "fanuc_description@" + rev.stdout.strip()
    pkg_xml = os.path.join(
        os.path.expanduser("~/micromamba/envs/ros_jazzy/share/ur_description/package.xml")
    )
    if os.path.exists(pkg_xml):
        m = re.search(r"<version>([^<]+)</version>", open(pkg_xml).read())
        if m:
            return "ur_description@" + m.group(1)
    return "unknown"


def reexport_with_trimesh(src: str, workdir: str) -> str:
    """Some vendor DAEs carry malformed faces that break SceneKit's exporter (e.g. UR10e's
    upperarm: "face … vertex count (3) out of range"). trimesh drops them and the scene is
    written as OBJ + MTL for SceneKit to convert.

    Written by hand, one `usemtl` group per source part: trimesh's own OBJ export concatenates the
    scene into one mesh with a single material, which turned the UR10e upper arm plain white.
    Vertices are baked into the scene's node transforms, in the DAE's own (Z-up) coordinates,
    like trimesh's export; the OBJ path gets no axis wrap (see usdz_convert.swift)."""
    import numpy as np
    import trimesh  # only needed for the fallback; lives in the ROS env

    scene = trimesh.load(src, force="scene")
    stem = os.path.splitext(os.path.basename(src))[0]
    obj_path = os.path.join(workdir, stem + ".obj")
    mtl_name = stem + ".mtl"
    obj = [f"mtllib {mtl_name}"]
    materials: dict[str, tuple[float, float, float]] = {}
    base = 1
    for node in scene.graph.nodes_geometry:
        transform, geom_name = scene.graph[node]
        mesh = scene.geometry[geom_name]
        if not isinstance(mesh, trimesh.Trimesh) or len(mesh.faces) == 0:
            continue
        name, rgb = _part_material(mesh, geom_name)
        materials.setdefault(name, rgb)
        verts = trimesh.transform_points(mesh.vertices, transform)
        normals = mesh.vertex_normals @ np.asarray(transform)[:3, :3].T
        obj.append(f"o {re.sub(r'[^A-Za-z0-9_.-]', '_', str(node))}")
        obj += [f"v {x:.6f} {y:.6f} {z:.6f}" for x, y, z in verts]
        obj += [f"vn {x:.6f} {y:.6f} {z:.6f}" for x, y, z in normals]
        obj.append(f"usemtl {name}")
        obj += [
            f"f {a + base}//{a + base} {b + base}//{b + base} {c + base}//{c + base}"
            for a, b, c in mesh.faces
        ]
        base += len(verts)
    with open(obj_path, "w") as f:
        f.write("\n".join(obj) + "\n")
    with open(os.path.join(workdir, mtl_name), "w") as f:
        for name, (r, g, b) in materials.items():
            f.write(
                f"newmtl {name}\nKd {r:.4f} {g:.4f} {b:.4f}\nKa 0 0 0\nKs 0 0 0\nd 1\nillum 1\n\n"
            )
    return obj_path


def _part_material(mesh, fallback: str) -> tuple[str, tuple[float, float, float]]:
    """(material name, diffuse RGB 0..1) for one trimesh part, from its material or colours."""
    visual = mesh.visual
    material = getattr(visual, "material", None)
    rgba = None
    if material is not None:
        rgba = getattr(material, "main_color", None)
        name = getattr(material, "name", None) or fallback
    else:
        rgba = getattr(visual, "main_color", None)
        name = fallback
    if rgba is None:
        rgba = (200, 200, 200, 255)
    r, g, b = (float(c) / 255.0 for c in list(rgba)[:3])
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(name)), (r, g, b)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_converter(jobs: list[dict], workdir: str) -> list[dict]:
    if not jobs:
        return []
    jobs_path = os.path.join(workdir, f"jobs-{len(jobs)}.json")
    with open(jobs_path, "w") as f:
        json.dump(jobs, f)
    proc = subprocess.run(["swift", CONVERTER, jobs_path], capture_output=True, text=True)
    results = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]
    if not results:
        print(proc.stderr[-2000:])
        raise SystemExit("converter produced no results")
    return results


def main() -> None:
    uris: dict[str, tuple[str, str]] = {}
    for robot in ROBOTS:
        urdf = open(os.path.join(FIXTURES, robot, "robot.urdf")).read()
        # visual meshes only: <visual> … <mesh filename="package://pkg/rel"/>
        for block in re.findall(r"<visual>.*?</visual>", urdf, flags=re.S):
            for pkg, rel in re.findall(r'<mesh filename="package://([^/]+)/([^"]+)"', block):
                uris[f"package://{pkg}/{rel}"] = (pkg, rel)
    print(f"{len(uris)} visual meshes across {ROBOTS}")

    jobs = []
    meta = {}
    for uri, (pkg, rel) in sorted(uris.items()):
        src = resolve(pkg, rel)
        file = os.path.join(pkg, os.path.splitext(rel)[0] + ".usdz")
        dst = os.path.join(OUT, file)
        jobs.append({"src": src, "dst": dst})
        meta[dst] = {"uri": uri, "file": file, "sha256": sha256(src), "source": source_version(src)}

    entries = []
    failed = 0
    with tempfile.TemporaryDirectory() as work:
        results = run_converter(jobs, work)
        retry = []
        for r in results:
            m = meta[r["dst"]]
            if r["ok"]:
                m.update(
                    bytes=os.path.getsize(r["dst"]),
                    tris=r["tris"],
                    bbox=r["bbox"],
                    via="scenekit",
                    axis_fix_applied=r.get("wrapped", False),
                )
                entries.append(m)
                print(
                    f"ok   {m['uri']} → {m['file']} ({m['bytes'] / 1e6:.2f} MB, {m['tris']} tris)"
                )
            else:
                print(f"retry {m['uri']}: {r.get('error')} → re-exporting with trimesh")
                src = next(j["src"] for j in jobs if j["dst"] == r["dst"])
                retry.append({"src": reexport_with_trimesh(src, work), "dst": r["dst"]})
        for r in run_converter(retry, work) if retry else []:
            m = meta[r["dst"]]
            if r["ok"]:
                m.update(
                    bytes=os.path.getsize(r["dst"]),
                    tris=r["tris"],
                    bbox=r["bbox"],
                    via="trimesh-obj+scenekit",
                    axis_fix_applied=r.get("wrapped", False),
                )
                entries.append(m)
                mb = m["bytes"] / 1e6
                print(f"ok   {m['uri']} → {m['file']} ({mb:.2f} MB, {m['tris']} tris, via trimesh)")
            else:
                failed += 1
                print(f"FAIL {m['uri']}: {r.get('error')}")

    manifest = {
        "version": 1,
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "robots": ROBOTS,
        "entries": sorted(entries, key=lambda e: e["uri"]),
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "meshes.json"), "w") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    total = sum(e["bytes"] for e in entries)
    rel = os.path.relpath(OUT, ROOT)
    print(f"\n{len(entries)} converted, {failed} failed, {total / 1e6:.1f} MB → {rel}/meshes.json")
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
