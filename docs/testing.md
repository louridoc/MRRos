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
Scope decided with the user: initially a free drag-to-translate + two-finger-rotate gizmo (not
nudge buttons) — revised after device testing to axis-select-then-drag (see "fourth attempt"
below), on the user's advice from a prior AR app where free dragging had the same problems.
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
- Gizmo gestures on `ARContainerView` (superseded — see "fourth attempt" below for the current
  design): originally single-finger pan re-raycasting the floor under the touch point to
  translate, two-finger rotation for yaw, and a translucent "ghost" render while aligning.

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
real-world mesh can't compete with the model you're actively moving.

Device drill, fourth attempt (2026-11-17): occlusion fix was an improvement but the user judged
the whole free-drag interaction a bad idea on its own merits (also reported the robot looked
smaller, cause not diagnosed — moot once the mechanism below was replaced wholesale). Per the
user's own prior AR app (`~/xcode_ws/MCRL-AR-Swift-App`), which hit the same free-drag
unreliability and solved it with axis-select-then-drag, ported that pattern directly:
- `RobotScene.AlignAxis` (`.x`, `.z`, `.yaw`) + a segmented control, shown only while aligning.
- `AlignmentTransform.translatedLocally(byX:byZ:)` — moves along the alignment's OWN local axes
  (rotated by current yaw), matching the reference app's `localTranslate`.
- A single `UIPanGestureRecognizer`; `handlePan` reads only `translation(in:).x` (screen points,
  not any 3D raycast or ray/plane intersection — no ARKit geometry query of any kind) and routes
  it to whichever axis is selected, scaled by a constant (`1/1000` m/point for translation,
  `1/100` rad/point for yaw — taken from the reference app's already-tuned feel) and consumes
  the delta via `setTranslation(.zero, in:)` each event, mirroring the reference app's
  `sender.setTranslation(CGPoint.zero, ...)`. No floor raycasting, no occlusion interaction, no
  shallow-angle amplification — the entire class of bugs from the first three attempts doesn't
  apply to this design since no 3D geometry query is involved in the drag at all.
Dropped the two-finger rotation gesture and the free-translate pan entirely.

Device drill, fifth attempt (2026-11-17): the axis-select redesign made NO difference — robot
still snapped below the floor the instant a drag started, even though the new pan math only
ever touches X/Z/yaw and provably can't move Y. That ruled out the pan math itself across two
completely different implementations, which pointed at something underneath both of them:
every attempt so far mutated `AnchorEntity.transform` directly to move the robot.
`AnchorEntity` represents a point ARKit tracks, and there was never a confirmed guarantee that
manually overwriting its `.transform` doesn't get fought or partially overridden by RealityKit's
own anchor bookkeeping — which would explain a symptom that survived three independent fixes to
the gesture-handling code above it. Restructured so `anchor` is created once at the identity
transform and never touched again; a new plain child `Entity` (`alignmentRoot`) holds the robot
and gizmo, and its LOCAL transform (== world transform, since `anchor` is identity) is what
`alignment.transform` now drives. A plain `Entity`'s transform has no anchor-tracking behavior
to fight with. **Confirmed on device: "much better"** — the floor-sinking was the
`AnchorEntity` mutation all along; the occlusion/ghosting theory (third attempt) was a red herring.

Sixth pass (2026-11-17, user request): move relative to `base_link` with a visible triad.
- The previous X/Z buttons used AR-convention local axes; in `base_link` Z is up and the
  horizontal axes are X and Y, so they'd have contradicted a ROS triad. Axes are now
  `X` / `Y` / `Rotate Z`, computed in `AlignmentKit` (`worldVector(fromBaseLink:)`,
  `translatedInBaseLink(by:)`) — no axis swap in the app target.
- `BaseLinkTriad` (red X, green Y, blue Z, 0.4 m) is built in ROS coordinates under an entity
  carrying `FrameConventions.rosToAR` — the same rotation `RobotEntity` uses. Property test
  `drawnBaseLinkAxesMatchTheRegistrationFrame` proves a point `v` along the drawn axes registers
  as `v` through `CloudRegistration`'s path, i.e. triad = robot axes = uploaded cloud frame.
- X/Y drag is measured along the selected arrow's on-screen projection and scaled by its
  pixels-per-metre, so the base follows the finger along the arrow; falls back to horizontal
  drag at 1/1000 m/pt when the axis points at the camera. Rotate uses horizontal drag.
- While aligning: robot at 45% opacity, selected arrow full / others 30%, and scene occlusion
  off — the triad sits exactly at the real robot's base, so its LiDAR mesh would hide it.
- Cone tip orientation verified on the Mac (apex at +Y, centred) rather than on device.
- Device-confirmed by the user ("Perfect!"). Then added `Z` (vertical) translation on request:
  same drag-along-the-arrow mapping on the blue arrow; when looking straight down (Z
  foreshortened) the fallback is vertical drag rather than sideways. Registration already uses
  the full position, so raising the base raises the cloud's `base_link` origin with it.

Device drill, not yet (re-)done:
- [x] Virtual robot overlays the real one using the X/Y/Z/Rotate Z axis-select drag (2026-11-17)
- [~] Waived by the user (2026-11-17): room scan judged "close enough" in RViz; not measured. A cloud of a box placed at a measured offset appears at that offset in RViz (quantitative
      check — validates the gizmo's resulting transform and the registration path together)
- [x] Gesture feel on a real phone — "works great" (2026-11-17)

## M4b — Save/restore alignment (ARWorldMap)
Design: on "Done" aligning, an `ARAnchor` named `mrros.base_link` is placed at the aligned pose
and ARKit's world map (which carries it) is archived to `Application Support/MRRos/alignment`
with JSON metadata (robot name, time). "Restore saved" re-runs the session with
`initialWorldMap` and rebuilds the robot at that anchor once tracking is `.normal` again.
Restoring from the anchor (not a stored pose) lets ARKit's own map refinement carry over.
Choices: restore is a button, not automatic at launch (relocalizing resets the session and just
waits if you're elsewhere); save is automatic on Done but only when `worldMappingStatus` is
`.mapped`/`.extending`; one slot. A restore clears the in-progress scan.

Automated: `tools/ios-test.sh AlignmentKit` — `AlignmentStore` (platform-neutral; the map is
opaque `Data` there): empty → nothing to restore, save/load round-trip, overwrite, clear is
idempotent, metadata without a map → `.corrupt`, unreadable metadata → treated as nothing saved.
The `ARWorldMap` archive/relocalization itself is device-only (no simulator/Mac equivalent).

Races caught in self-review before any device test:
- For a moment after `session.run(..., .resetTracking)` `currentFrame` can still be from the
  OLD session — tracking `.normal`, possibly holding an earlier base_link anchor — which would
  have "restored" instantly in the wrong frame. Frames older than the restore are now ignored.
- Replacing the anchor before a save is a remove + add, but frames from before that call still
  contain the old anchor. The save now tracks the new anchor by identifier and rejects a map
  unless it holds exactly that one robot anchor.

Device drill:
- [x] Align → Done saves ("Alignment saved"); if it says "hasn't mapped enough", walk around the
      robot and Done again
- [x] Kill the app, relaunch, connect → "Restore saved · <robot> · <time>" appears
- [x] Restore → "Relocalizing…" → robot reappears overlaying the real one (status says
      "restored — check it overlays the real robot")
- [ ] Restore while pointing somewhere unrelated stays "Relocalizing…"; tapping Place robot
      abandons the restore cleanly
- [ ] Forget (ⓧ) removes the restore row; it stays gone after relaunch
- [ ] Scan after a restore lands in RViz consistent with a scan from the original session

Core save → relaunch → restore flow device-confirmed ("Works!", 2026-11-17); the edge cases
above (unrelated-area restore, Forget across relaunch, post-restore scan) not explicitly checked.

## M5a — Planning-scene research spike
Write-up: `docs/research/m5a-scene-ingestion.md` (verified vs documentation-only claims marked).

Automated end-to-end check (run on the Mac, both vendors): `tools/moveit_scene_check.py` uploads a
wall + points sampled on the robot's own collision meshes through ar_bridge's HTTP endpoint and
asserts: blocked pose becomes invalid, start stays valid (self-filter), goal clear, OMPL plan found,
every waypoint collision-free.
- [x] UR10e — 2/2 runs pass (2026-11-18)
- [x] CRX-30iA (`positions:="0,0.7,0,0,0,0"`) — 3/3 runs pass (2026-11-18)

Findings log:
- 2026-11-18: `move_group` invisible to every other node. Ruled out RMW mismatch (all CycloneDDS),
  launch context, and UDP message size (CYCLONEDDS_URI tried, reverted). Cyclone tracing showed
  others discovered move_group but it discovered no one → incoming traffic blocked → macOS
  application firewall had no rule for the new binary. User allowed it; fixed.
- 2026-11-18: octomap updater plugin missing — RoboStack's `moveit` doesn't pull in
  `moveit_ros_perception`; installed and added to the env template.
- 2026-11-18: CRX plans failed three different ways, none of them MoveIt bugs: my test wall's
  inner corridor (0.35 m) was swept by the CRX's offset shoulder housing (→ 0.5 m); Ruckig
  smoothing failed under FANUC's 0.4 rad/s² limits (dropped for planning-only); FANUC's OMPL
  config is keyed to group `arm` vs SRDF group `manipulator`, so its collision-check resolution
  never applied and OMPL accepted a path grazing the wall (set on the real group, 0.005).
- 2026-11-18: an early version of the check sampled "robot" points on straight lines between link
  frame origins — those aren't on a UR's arm, so they weren't (correctly) filtered. Now sampled on
  the actual collision meshes from `/robot_description`.
- 2026-11-18: a MoveIt started after an upload never sees it; a cloud arriving in move_group's
  first seconds isn't self-filtered (silently). Drives the M5c "clear-then-publish, repeatedly"
  design.
- 2026-11-18 (M3 bug, found during an M5 device test): EXC_BAD_ACCESS in `worldVertices` on a
  ~98k-point scan. Vertices were read as `SIMD3<Float>` (16 bytes, 16-aligned) from ARKit's packed
  `.float3` buffer (12-byte stride): misaligned reads, and the last vertex over-read 4 bytes past
  the buffer — crashing only when that end landed on a page boundary, so M3's smaller scans never
  hit it. Now reads 3 unaligned `Float`s per vertex and checks the source format.

## M5 — Fake trajectory execution (dev-only)
`mock_joints` is now also a fake `FollowJointTrajectory` controller
(`mrros_mock_controller/follow_joint_trajectory`): trajectories are played back onto
`/joint_states` (linear interpolation, final pose held; preempt/cancel supported) and MoveIt is
configured to use it with `moveit.launch.py execute:=true` (default; `false` = planning only).
Simulation only — real motion commands remain a v1 non-goal. Playback logic is rclpy-free
(`trajectory_playback.py`) with pytest coverage.

Automated: `tools/moveit_scene_check.py --execute` additionally executes the plan and asserts MoveIt
reports success and `/joint_states` ends at the goal.
- [x] CRX-30iA — 5/5 back-to-back runs, no settle wait, first right after startup (2026-11-18)
- [x] UR10e — 4/4 same conditions (2026-11-18)
- [ ] Device: Plan & Execute in RViz moves the AR robot on the phone (follows /joint_states)

Findings log:
- 2026-11-18: repeated --execute runs failed in three ways, two of them test geometry: the next run
  starts at the last goal, so +120° more left the CRX's ±180° J1 range (script now swings toward the
  side with room); swinging the other way, the CRX's shoulder housing (~50° off the arm direction,
  out to ~0.5 m) leads instead of trails and started inside a 0.5 m corridor (→ 0.7 m).
- 2026-11-18: the third was real and is the root cause of M5a's "first seconds" finding: an
  intermittent `shape_mask: Missing transform` — the self-filter looks up robot link TF at the
  cloud's exact stamp, which ar_bridge set to "now", often newer than the last joint TF. ar_bridge
  now stamps the static cloud 0 (latest transform). 0 missing-transform errors in 9 runs since.
- 2026-11-18 (device test): after Clear in the app and "Clear octomap" in RViz, new uploads still
  showed old points. Two causes. (1) App: Clear only emptied our buffer, but Capture harvests
  ARKit's whole fused scene mesh, so previously-seen surfaces came straight back — Clear now also
  re-runs the session with `.resetSceneReconstruction` (tracking untouched: world frame, alignment
  and robot stay; skipped on the restore path). (2) MoveIt: the octomap only ever adds; ar_bridge
  now calls `/clear_octomap` before every publish (no-op without MoveIt, 2 s timeout), so an upload
  replaces the scene there too — verified live (box → small far cloud: blocked pose becomes free).
- 2026-11-18: OMPL occasionally accepted UR paths grazing the wall (state 9/25 rejected by
  ValidateSolution) at MoveIt's default 0.5% collision-check step (~0.15 rad on ±360° joints).
  Now 0.2% for every robot: 6/6 UR10e + 6/6 CRX-30iA --execute runs pass, planning ≤ 0.12 s.
- 2026-11-18 (device test, follow-up): user saw RViz still showing old points after pressing
  Clear. Measured MoveIt's octomap (decoded the octree from /get_planning_scene): it held exactly
  the last upload — uploads were replacing correctly. The gap was Clear itself: it only reset the
  phone, sending nothing to ROS, so RViz kept the last upload until the next one. Added
  `DELETE /v0/cloud` (drops stored scan, clears MoveIt's octomap, publishes an empty latched cloud)
  and the app's Clear calls it. Verified live: blocked pose free again, latched topic width 0, and
  MoveIt's /monitored_planning_scene broadcast (what RViz draws) goes from a 283 KB octomap to empty.
- [x] Device: press Clear in the app → RViz's octomap empties without uploading (2026-11-18)
- 2026-11-18 (device test, second follow-up): after Clear, a capture 5 s later still had ~19k
  points — the ARKit mesh reset wasn't happening. It only ran if `session.configuration` could be
  read back as a world-tracking config, and silently skipped otherwise; RealityKit's default
  `automaticallyConfigureSession` also re-runs the session with its own config (e.g. when align
  mode toggles occlusion). Fixed: ARView created with `automaticallyConfigureSession: false`, and the
  reset falls back to our own `makeConfiguration()` instead of skipping. Capture's status now shows
  ARKit mesh pieces/vertices and time since the reset. Device-confirmed: reset runs; a capture after
  Clear contains only what the camera has seen since (ARKit meshes continuously, so "since Clear"
  includes everything swept past — choosing a region is M5b's crop box).

## M5b — Scan preview, robot filter, crop
Built: green/red/grey AR preview of the scan (uploaded / robot / cropped out); robot filter =
per-link mesh bounds at the AR robot's pose + 3 cm (MoveIt's padding); crop box in base_link
(default ±0.8 m X/Y, −0.05…1.4 m Z — the first default, ±1.5 m / 2 m, was too big on device), edited Move/Size × X/Y/Z with the alignment-style drag, base
triad shown while editing; re-filtered when the finger lifts. Only green points are uploaded.

Device drill:
- [x] Preview overlays the captured surfaces (after the anchor fix below) (2026-11-18)
- [ ] Real robot's surfaces red; not too much of the surroundings red
- [ ] Crop on → yellow box around the robot; points outside turn grey after editing
- [ ] Edit → Move/Size along X/Y/Z follows the finger; triad highlights the active axis
- [ ] Upload → RViz shows only green points
- [ ] No lag on Capture or while editing the crop (after the threading change below)
- [ ] + Exclude → orange 30 cm box at the surface under the screen centre; points inside turn orange
      and aren't uploaded; several boxes, chips select which one a drag edits, trash deletes it
- [ ] Exclusion boxes: Move/Size along their own axes, Rotate about vertical; triad sits on the
      selected box and turns with it
- [ ] Re-aligning the robot moves crop + exclusion boxes with it (all in base_link, by choice)
- [ ] Clear deletes the exclusion boxes (crop box stays)

Automated: `tools/ios-test.sh LiDARScan` — `OrientedBox` containment (padding, translation,
rotation), `SceneFilter.classify` (robot wins over crop, no-crop/no-robot keeps all, padding),
`PointCloud.selecting` keeps columns aligned.

Findings log:
- 2026-11-18 (device): preview points appeared away from where they were captured ("to my left
  and back") while the same scan uploaded correctly to RViz. The preview's world anchor was made
  once at app launch; RealityKit backs world anchors with ARKit anchors, and a restore
  (`.resetTracking, .removeExistingAnchors`) moves the world frame and drops them, stranding the
  preview by exactly that jump. Now re-created on every redraw (same lifetime as the robot's).
  Device: "way better".
- 2026-11-18 (device): Capture and crop edits lagged. Everything ran on the main thread, and each
  capture re-voxelized the whole accumulated scan from scratch. Now: the main thread only memcpy's
  ARKit's vertex buffers (`MeshChunk`); a `ScanProcessor` actor transforms them into a persistent
  `VoxelAccumulator` (only new points touched; re-captured surfaces refine, don't grow — tested),
  classification + preview geometry + upload registration/PLY encoding run detached, meshes are
  created with RealityKit's async `MeshResource(from:)`, stale results are dropped (epoch for Clear,
  generation for previews), crop drags only move the box (label + re-filter on lift), preview draw
  cap 40k → 25k per class. Clear is race-free against a pending capture via the epoch, not a reset
  message (actor message order across separate Tasks isn't guaranteed).
- 2026-11-18 (design, with the user): exclusion boxes added alongside crop — crop keeps what's
  inside one box, exclusion boxes drop what's inside any of them (priority robot > excluded >
  outside crop). User's choices: several exclusion boxes, attached to the robot (base_link, like
  crop — they move with re-alignment), and Clear deletes them. Shared `BaseLinkBox` type
  (centre/half/yaw, AlignmentKit, tested). Safety note: excluded space reads as FREE to MoveIt
  (no data = free), so the preview always shows excluded points in orange.
- 2026-11-18 (device): "too many panels blocking the AR view". Chosen with the user: mode tabs —
  one compact bottom panel (single status line, edit pickers only while editing, action row of the
  active tab, Robot | Scan switch); joints panel behind a toggle next to the connection pill.
  Switching tabs ends that tab's drag mode. Layout checked in the iOS Simulator (overlay only —
  no ARKit there).
- [ ] Device: AR view mostly unobstructed; both tabs usable one-handed
