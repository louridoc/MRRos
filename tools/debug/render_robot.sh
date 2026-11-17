#!/usr/bin/env bash
# Render a robot (real RobotModel/RealityKit pipeline, no phone needed) for orientation debugging.
# Builds tools/debug/RobotViz on first run (fast after that).
#
# Usage:
#   tools/debug/render_robot.sh [robot] [out.png] [extra args to RobotViz...]
#
# Examples:
#   tools/debug/render_robot.sh crx30ia                      # home pose, default camera
#   tools/debug/render_robot.sh ur30 /tmp/ur30.png --distance 3 --azimuth 60
#   tools/debug/render_robot.sh crx30ia /tmp/x.png --positions J1=0.5,J2=-0.3
#
# Debugging a NEW orientation bug (don't trust single-mesh tests — a symmetric part like a base
# can look "upright" at more than one wrong rotation; always confirm on the full assembly):
#   tools/debug/render_robot.sh crx30ia /tmp/t0.png   --mesh-test-rot-deg 0
#   tools/debug/render_robot.sh crx30ia /tmp/t90.png  --mesh-test-rot-deg 90
#   tools/debug/render_robot.sh crx30ia /tmp/t180.png --mesh-test-rot-deg 180
#   tools/debug/render_robot.sh crx30ia /tmp/t270.png --mesh-test-rot-deg 270
# then look at all four and pick the one where the robot stands upright. See the comment at the
# top of tools/meshes/usdz_convert.swift for how that angle becomes the real fix.
#
# M2b (a robot NOT in the bundle, meshes fetched from ar_bridge over HTTP) — test this on the
# Mac before ever touching the phone:
#   1. ros2 launch ar_dev_bringup dev.launch.py robot:=ur16e rviz:=false   # ar_bridge:=true (default)
#   2. ros2 run xacro xacro $(ros2 pkg prefix ur_description)/share/ur_description/urdf/ur.urdf.xacro \
#        name:=ur ur_type:=ur16e > /tmp/ur16e.urdf   # or any robot with no fixture under ios/Packages/URDFKit/Tests/Fixtures
#   3. tools/debug/render_robot.sh _ /tmp/ur16e.png --urdf /tmp/ur16e.urdf --ar-bridge-url http://localhost:8765
# A second run with --ar-bridge-url omitted should render identically from the disk cache alone
# (~/Library/Caches/Meshes), with no network access — proving the cache tier actually works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROBOT="${1:-crx30ia}"
OUT="${2:-/tmp/robotviz_${ROBOT}.png}"
shift $(( $# >= 2 ? 2 : $# ))

cd "$ROOT/tools/debug/RobotViz"
swift build -c release 2>&1 | grep -E "error:|Compiling|Build complete" || true
.build/release/RobotViz --robot "$ROBOT" --out "$OUT" "$@"
