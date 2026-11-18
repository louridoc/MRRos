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

## M3 — Scan → RViz
Automated: `tools/ios-test.sh LiDARScan AlignmentKit ARBridgeTransport` (PLY encode/decode
round-trip incl. a regression test for the small-cloud ASCII-prefix bug below, voxel filter,
`uploadCloud` query/body/status-mapping against a mocked transport), `cd ros2_ws && tools/ros.sh
jazzy pytest -q` (`ply.py` decode/encode/merge incl. a fixture shaped like the Swift encoder's
exact header, `cloud.py`'s `build_point_cloud2`/`write_pcd`/`ingest`, `/v0/cloud`'s error-status
mapping in `http_api.py`).

Mac-side end-to-end check (no phone), same discipline as M2b:
- [x] `ros2 run ar_bridge ar_bridge` alone (no bringup needed for this endpoint) → hand-built
      420-point colored PLY POSTed to `/v0/cloud?frame_id=map&name=m3test` via curl: `200` with
      correct point count, `.pcd` file on disk with the right header/point count, topic
      structurally correct via `ros2 topic echo` (5 fields incl. packed `rgb`, 20-byte aligned
      `point_step`), and visually confirmed in a live RViz (floor + wall, correct colors) (2026-11-17)
- [x] Second POST with `mode=append` and no confidence/color (tests the backfill path) →
      420+10=430 points, confirmed via `ros2 topic echo` (2026-11-17)
- [x] Real Swift-side client (`LiDARScan.PLYCodec.encode` → `ARBridgeTransport.ARBridgeClient.
      uploadCloud` over real `URLSessionHTTPTransport`, not the mocked transport) against the
      live node: 5000-point cloud uploaded and accepted (2026-11-17)
- [x] Full app target builds (`tools/ios-build.sh`) with the capture/preview/upload UI
      (`ScanScene`, `ScanSheet`, `ARContainerView.Coordinator.captureScan/clearScan/uploadScan`)

Device drill:
- [x] Real on-device scan (CRX-30iA dev bringup): app captured and uploaded a real
      `ARMeshAnchor`-derived cloud (10801 → 48893 points across several captures), `ar_bridge`
      logged it received and published each one (2026-11-17)
- [x] Cloud confirmed visible in RViz, resembling the real room, after the `map`-frame fix
      below (2026-11-17)
- [ ] Cloud roughly aligned with the placed robot — not yet re-tested on device after the
      placement-registration fix below
- [x] 1M-point upload timing: 1.6 s end-to-end over loopback (decode 0.02 s, `build_point_cloud2`
      0.37 s, `write_pcd` 1.2 s) after the fix below — comfortably under 5 s with real Wi-Fi
      transfer time added on top (2026-11-17)

Findings log:
- 2026-11-17: profiled the 1M-point ingest and found `write_pcd`'s Python per-point f-string
  loop was ~1.94 s of a 2.32 s total — nearly the whole cost. Replaced with `np.savetxt`
  (vectorized in C): 1.94 s → 1.2 s, total ingest 2.32 s → 1.59 s. Also moved `ingest()` (not
  just `decode()`) onto `run_in_executor` in `node.py`'s `_on_cloud`, since it was blocking the
  whole event loop (including concurrent `/health`/`/v0/mesh` requests) for that whole duration
  — `clock_now` is read before dispatching, not inside the executor thread, to avoid calling
  rclpy's clock off the node's own thread.
- 2026-11-17: user placed the robot, then scanned, and expected the cloud to land roughly where
  the robot was placed — it didn't, because the scan was uploaded relative to the AR session's
  arbitrary world origin (`frame_id=map`) with no relationship to the placement anchor at all.
  Fixed in `ARContainerView.Coordinator`: `place()` now remembers `hit.worldTransform`
  (`placementTransform`); `uploadScan()` re-expresses the scan relative to that anchor's
  position (translation only — full 6-DOF is still M4's manual gizmo) and uploads with
  `frame_id=base_link` whenever a robot is placed, falling back to the old unregistered `map`
  behavior only if nothing has been placed yet. Recomputed fresh at upload time (not baked in at
  capture time) so re-placing the robot doesn't require re-scanning.
- 2026-11-17: the Scan controls were a `.sheet` (`ScanSheet`), which covers the camera feed while
  open — unusable for a workflow that requires watching the room while tapping Capture. Replaced
  with `ScanBar`, an always-visible overlay over the AR view, same pattern as `PlacementBar`.
- 2026-11-17: on-device scan uploaded successfully (`ar_bridge` logged the correct point counts)
  but never appeared in RViz. Root cause: the app uploads with `frame_id=map` (by design, see
  `ar_bridge_http.md` — `map` is a placeholder pre-M4 since there's no real alignment yet), but
  `dev.launch.py` never published a `map` TF frame at all, and `dev.rviz`'s `PointCloud2` display
  (which *was* correctly configured — a `grep` miss during triage falsely suggested otherwise,
  due to BSD `grep`'s `\|` not meaning alternation) had no way to transform into Fixed Frame
  `base_link`. Verified all 7 robots in `robots.py` root their TF tree at `world` with no parent
  (expanded every xacro and diffed link defs against joint children); fixed by adding a single
  identity `static_transform_publisher` (`map` → `world`) to `dev.launch.py`, uniform across
  robots. Verified via `tf2_echo map base_link` resolving to the expected 0.75 m CRX pedestal
  offset. Not yet re-confirmed on device (next step).
- 2026-11-17: `PLYCodec.parseHeader` (Swift) originally located `end_header` by decoding
  `data.prefix(4096)` as ASCII — fails whenever a small cloud's binary payload falls inside that
  window and isn't valid ASCII. Caught by self-review before running any tests, not by a test
  failure; fixed by searching for the literal `end_header\n` byte marker first. Applied the same
  fix proactively to the Python decoder (`ply.py`) and locked it in with a named regression test.

## M4 — Alignment (in progress)
Scope decided with the user: drag-to-translate + two-finger-rotate gizmo (not nudge buttons);
`ARWorldMap` save/restore deferred to a follow-up (M4b) after this pass is device-verified.

Automated: `tools/ios-test.sh AlignmentKit` — `AlignmentTransform` property tests (identity is a
no-op, the anchor's own position always maps to the ROS origin regardless of yaw, yaw rotates
about the vertical axis, translate/rotate deltas compose correctly, `pointInBaseLink` round-trips
through the forward transform, `.from(worldTransform:)` extracts position exactly and is
self-consistent with `.transform`) and `CloudRegistration` tests (matches `FrameConventions`
per-point, preserves confidence/color/count, identity alignment equals plain axis rotation,
registering places the alignment's own anchor at the ROS origin, yaw=0 case matches simple
subtraction — i.e. M3's old stopgap is a special case of the new general path).

Built this pass:
- `AlignmentKit.AlignmentTransform` — position + yaw (not full 6-DOF: robots are bolted to a
  level floor and the initial placement is already a gravity-aligned horizontal-plane raycast,
  so pitch/roll aren't a real DOF worth exposing).
- `AlignmentKit.CloudRegistration` — moved the point-cloud transform logic out of the app
  target into here (it's pure math, no ARKit dependency) so it's actually unit-testable, per
  CONTRIBUTING.md's "no logic that belongs in a package" rule. `captureScan` now stores raw AR-world
  points; both the ROS-axis rotation and the alignment registration happen together at upload
  time, recomputed from whatever the CURRENT alignment is — re-aligning doesn't require
  re-scanning.
- Gizmo gestures on `ARContainerView`: single-finger pan re-raycasts the floor under the touch
  point (same raycast `place()` uses) to translate; two-finger rotation adjusts yaw. Both are
  no-ops unless `RobotScene.isAligning` is on (an explicit "Align" button, not always-live, to
  avoid accidental nudges during normal viewing).
- Overlay check view: while aligning, the robot renders at 40% opacity (`OpacityComponent`) so
  it's visually obvious you're comparing against the camera passthrough, not just looking at an
  opaque model; reverts to opaque on "Done".

Device drill, first attempt (2026-11-17): three real problems, all fixed same session, not yet
re-verified on device:
- **No visible gizmo** — there was nothing on screen indicating align mode or offering something
  to look at besides the robot itself. Added an actual gizmo entity (translucent cyan disc +
  red heading arrow, `UnlitMaterial` so it reads regardless of scene lighting), child of the
  placement anchor so it tracks position/yaw automatically, shown only while aligning.
- **Robot too transparent** — 40% opacity made it hard to actually judge overlap against the
  real robot. Raised to 75%; the gizmo (not heavy ghosting) is now what signals "you're in align
  mode."
- **Robot drops below the floor on touch** — the real bug. `handlePan` re-raycasted
  `.estimatedPlane` at the touch point on every move; ARKit's plane *estimation* (not just
  detection) can return a hit on a different, spurious, or lower-than-true-floor plane,
  especially right where the user is touching to "grab" the robot. Replaced with deterministic
  ray/plane math: intersect the camera ray through the touch point with the horizontal plane at
  the robot's own current height (`ARView.ray(through:)`, no ARKit plane detection involved at
  all) — the Y coordinate can no longer drift from a bad plane hit.

Device drill, second attempt (2026-11-17): dragging was "awful" — reported symptoms were
"too sensitive / overshoots" and "snaps to the wrong place" (rotation untested). Root cause:
`handlePan` set the robot's position to the *absolute* ray/floor-plane projection of the touch
point on every `.changed` event, rather than moving it by how far the touch had moved. That
snaps the robot to wherever your finger currently is (not where you started touching — "wrong
place"), and at shallow viewing angles a small finger movement maps to a large change in that
projected point ("overshoots"). Fixed by switching to relative-delta dragging: `.began` records
the touch's floor-projection and the alignment's starting position; `.changed` moves by the
difference between the current and starting projections, added to the starting position — the
standard pattern for dragging an object across a plane in AR, used by essentially every
placement app.

Device drill, third attempt (2026-11-17): user reported the relative-delta fix made no
difference — robot still "goes below the floor" the moment it's touched. The pan math is
provably unable to move Y at all (the ray/plane intersection is solved so both the start and
current touch projections land exactly on the robot's current height — their difference has a
y-component of exactly 0 by construction), so this is very unlikely to be an actual position
bug. Best diagnosis without being able to see the device: the OTHER change bundled into the
previous fix — ghosting the robot via `OpacityComponent` while aligning — is the real culprit.
Alpha-blended geometry typically doesn't write to the depth buffer the way opaque geometry does,
so with `sceneUnderstanding.options = [.occlusion]` still enabled, the real-world LiDAR
occlusion mesh can clip through/hide a translucent model in ways it never could against an
opaque one, which would visually read as "sinking into the floor" with no actual transform
change. Fix: dropped the opacity ghost entirely (robot stays fully opaque throughout; the gizmo
disc/arrow is what signals align mode now) and disable scene occlusion while aligning so the
real-world mesh can't compete with the model you're actively moving. **Not yet re-verified on
device — this is a diagnosis from reading the code, not a confirmed root cause.**

Device drill, not yet (re-)done:
- [ ] Virtual robot overlays the real one after dragging/rotating with the gizmo
- [ ] A cloud of a box placed at a measured offset appears at that offset in RViz (quantitative
      check — validates the gizmo's resulting transform and the registration path together)
- [ ] Gesture feel on a real phone (pan precision, rotation sign/direction, whether the new
      ray-plane pan feels responsive)
