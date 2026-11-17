# Testing

Automated: `tools/ios-test.sh` (Swift, macOS), `cd ros2_ws && tools/ros.sh <distro> pytest -q`
(ROS), `tools/it.sh <distro>` (integration against a live local bringup). CI runs the Swift
suite on macOS and the ROS suite + launch smoke test on Humble, Jazzy and Lyrical containers.

Device checklists below are run manually at each milestone and the result noted in the PR.

## M0 — Environment
- [x] `tools/ros-env.sh create jazzy` and `tools/ros-build.sh jazzy` succeed (2026-11-15, Python 3.14 in env)
- [x] all 7 catalog robots expand via xacro with expected joint names and `base_link` (crx30ia, crx20ial, ur30, ur20, ur10e, ur10, ur16e)
- [x] headless bringup: rosbridge :9090, `/joint_states` 29.95 Hz, `/robot_description`, `/tf`, `/tf_static`; a websocket client received `JointState` for J1–J6 (crx30ia)
- [x] `tools/it.sh jazzy crx30ia` → `integration OK`
- [x] ROS pytest: 7 passed under Python 3.10 (uv), 3.12 (uv) and 3.14 (env)
- [x] `tools/ros.sh jazzy ros2 launch ar_dev_bringup dev.launch.py robot:=crx30ia` → CRX-30iA in RViz, joints sweeping (visual, 2026-11-15)
- [x] same with `robot:=ur30` (visual)
- [ ] CI green on humble / jazzy / lyrical — **blocked: GitHub Actions `startup_failure` at account level** (billing/private-repo minutes); re-check after fixing the account
- [x] `tools/ios-test.sh` → all 10 packages green
- [x] `tools/ios-build.sh` → BUILD SUCCEEDED (generic iOS Simulator)
- [x] Signed device build (team XXXXXXXXXX), installed via `devicectl`, app shows the AR view on the iPhone (2026-11-15)

M0 exit test met except CI, which is an account issue, not a repo issue.

## M1 — Connectivity
Automated: `tools/ios-test.sh ROSBridgeClient ROSMessages AppCore` (mocked transport, recorded
fixtures), `tools/it.sh jazzy` (live rosbridge), `tools/it-deadbridge.sh jazzy` (silent peer →
heartbeat must trip within ~1 s).

Device drill (bringup on the Mac, phone on the same Wi-Fi):
- [x] Connection sheet → host/port → Connect: capsule green, "<host> · <robot name>", topics listed (2026-11-15)
- [x] Joints panel shows J1–J6 (CRX-30iA) sweeping at ~30 Hz
- [x] **Liveness:** turn the Mac's Wi-Fi off → within ~5 s capsule turns yellow "Reconnecting (n)…" and the joints panel greys out with "⚠ stale Ns" (2026-11-15, third build)
- [x] Turn Wi-Fi back on → capsule green again and joints resume without user action
- [x] Kill and restart the bringup as another robot (`robot:=ur30`, ~7 s outage) → app reconnects by itself, robot name and joint names update to `ur` / `shoulder_pan_joint…`

M1 exit test met (2026-11-15).

Findings log:
- 2026-11-15: first drill showed "connected" for >30 s after Wi-Fi off (half-open TCP). Fixed with a
  2 s websocket heartbeat; second drill still stuck → the ping continuation ignored cancellation and
  froze the heartbeat task group. Reproduced locally with `tools/fake_dead_bridge.py`; fixed.

## M2a — Robot in AR
Automated: `tools/ios-test.sh URDFKit RobotModel MeshProvider AlignmentKit` (FK-vs-`/tf` exact
match, mesh bundle coverage). Orientation/placement regressions: render on macOS first with
`tools/debug/render_robot.sh <robot>` (real RobotModel/RealityKit code, no phone) before ever
touching the device — see the header of `tools/meshes/usdz_convert.swift` for why a single
isolated mesh is not a conclusive test.

Device drill (bringup on the Mac, phone connected):
- [x] Place robot (floor raycast) → CRX-30iA appears standing upright on the floor, correct
      scale, base/J1–J6 all present, joints animate in sync with the panel (2026-11-16)
- [x] No floating offset (base_link, not the URDF's `world` mount link, sits at the anchor)
- [x] Mac-side render (`tools/debug/render_robot.sh`) confirmed upright for all 5 priority
      robots (crx30ia, crx20ial, ur30, ur20, ur10e) before the device check

M2a exit test met (2026-11-16). Two defects found and fixed same night: ~0.75 m float
(anchored the URDF's structural root instead of `base_link` — fixed via
`URDFRobot.baseFrame`) and mesh orientation (DAE up-axis wrap was 180° about X, needed 90°;
first "fix" tested correct in isolation but was wrong on the full assembly — see
`tools/debug/RobotViz`).

## M2b — Robot in AR (any URDF)
Automated: `tools/ios-test.sh ARBridgeTransport MeshProvider` (mocked HTTP transport, both
success and every documented error status), `cd ros2_ws && tools/ros.sh jazzy pytest -q`
(`mesh_resolver` — URI parsing, package resolution, trimesh conversion with a real tiny STL
fixture, atomic caching).

Mac-side end-to-end check (no phone), per `tools/debug/render_robot.sh`'s M2b section — run
before any device check, same discipline as M2a:
- [x] `ros2 launch ar_dev_bringup dev.launch.py robot:=ur16e` → `ar_bridge` live, `GET /health`
      and `GET /v0/mesh?uri=package://ur_description/meshes/ur16e/visual/forearm.dae` both
      correct over real HTTP (curl), `X-Mesh-SHA256` present, body is valid OBJ (2026-11-17)
- [x] UR16e (no bundled meshes at all — only `forearm.dae`/`upperarm.dae` are UR16e-specific;
      base/shoulder/wrist1-3 resolve from the bundled UR10e meshes it shares them with) renders
      correctly via `RobotViz --ar-bridge-url`: standing upright, arm extended per the standard
      UR zero-pose convention, fetched (gray, untextured) and bundled (white) parts seamlessly
      joined — proving net-identity OBJ loading needs no up-axis correction, unlike DAE/USDZ
- [x] Re-render with `--ar-bridge-url` **omitted** → bit-identical image from the tier-2 disk
      cache alone (`~/Library/Caches/Meshes/ur_description/meshes/ur16e/visual/*.obj`), no
      network touched — the caching contract in `docs/protocols/ar_bridge_http.md` holds

- [x] Device check: connected to the live UR16e + `ar_bridge` bringup, placed the robot — UR16e
      appeared correctly, fetched meshes loaded over the network (2026-11-17)

M2b exit test met (2026-11-17), Mac-side and device.
