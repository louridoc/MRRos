#!/usr/bin/env python3
"""Build the bundled mesh set: every *visual* mesh referenced by the priority robots' URDF
fixtures, converted to USDZ with Apple's SceneKit, plus a manifest the app uses for lookup.

Output (committed):
  ios/MRRos/Meshes/<package>/<relative path>.usdz
  ios/MRRos/Meshes/meshes.json   — {"version", "generated", "entries": [{uri, file, sha256, bytes, tris, bbox, source}]}

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


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


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

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(jobs, f)
        jobs_path = f.name
    proc = subprocess.run(["swift", CONVERTER, jobs_path], capture_output=True, text=True)
    entries = []
    failed = 0
    for line in proc.stdout.splitlines():
        if not line.startswith("{"):
            continue
        r = json.loads(line)
        m = meta[r["dst"]]
        if not r["ok"]:
            failed += 1
            print(f"FAIL {m['uri']}: {r.get('error')}")
            continue
        m.update(bytes=os.path.getsize(r["dst"]), tris=r["tris"], bbox=r["bbox"])
        entries.append(m)
        print(f"ok   {m['uri']} → {m['file']} ({m['bytes'] / 1e6:.2f} MB, {m['tris']} tris)")
    if proc.returncode != 0 and not entries:
        print(proc.stderr[-2000:])
        raise SystemExit("converter failed")

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
    print(
        f"\n{len(entries)} converted, {failed} failed, {total / 1e6:.1f} MB → {os.path.relpath(OUT, ROOT)}/meshes.json"
    )
    if failed:
        raise SystemExit(1)


main()
