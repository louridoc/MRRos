# MRRos — AR ↔ ROS 2 Scanning & Robot Alignment App

**Status:** draft v0.1 (2026-11-15) — pending approval before scaffolding
**Owner:** Christian Lourido (44009617+louridoc@users.noreply.github.com)

## 1. Goal

An iPhone (LiDAR) AR app that joins a local ROS 2 network to:

1. Scan the environment and publish a static point cloud (topic + file) that updates a
   manipulator's planning scene and is visible in RViz.
2. Read the robot description, TF and joint states from the network, spawn the robot in AR,
   and let the user align the virtual robot with the real one so the scan is expressed in the
   robot's frame.

Non-goals for v1: sending motion commands, multi-robot, non-LiDAR devices.

## 2. Decisions (locked 2026-11-15)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | ROS 2 dev environment | **RoboStack Jazzy on the Mac** (micromamba) | rviz2, rosbridge, MoveIt2, ur_description all run natively on Apple Silicon → fastest loop. Lab PC only for the real UR16e. |
| D2 | Transport | **rosbridge (websocket, CBOR) + companion `ar_bridge` node** | Small/control traffic over rosbridge; bulk binary (point clouds up, meshes down) over HTTP to our node, which publishes native `PointCloud2`. |
| D3 | iOS stack | **RealityKit + ARKit + SwiftUI, iOS 18+**, Swift 6 | Clean break from the SceneKit/UIKit/CocoaPods app; Metal point rendering, USDZ, ECS. |
| D4 | Robot scope | **Generic URDF from the network; first-class support for FANUC CRX and UR e-series** (see §3.3) | Priority: CRX-30iA, CRX-20iA/L, UR30, UR20, UR10(e). Any URDF should load; these ship with bundled, pre-converted meshes and are the regression fixtures. |
| D5 | ROS distro | **Humble, Jazzy and Lyrical all supported; Jazzy is the default dev env** (see §3.4) | Lab machines may run any of the three LTS releases. The app is distro-agnostic by construction; the ROS packages are tested on all three in CI. |
| D6 | Scene output | **Latched `PointCloud2` + PCD/PLY file** | Works with RViz and MoveIt's octomap sensor plugin. Mesh CollisionObjects = later module. |
| D7 | Alignment | **Manual gizmo first, fiducial (AprilTag/ArUco via OpenCV) later** | Ship the frame math first; markers are an optimization. |
| D8 | Repo | **Private GitHub monorepo via `gh`** | `ios/`, `ros2_ws/`, `docs/`, `tools/` in one history. |

Changes to these go in `docs/adr/` as numbered ADRs.

## 3. Architecture

```
 iPhone (iOS 18+, LiDAR)                          Mac (dev) / Lab PC (prod) — ROS 2 Jazzy
 ┌──────────────────────────────┐                 ┌────────────────────────────────────────┐
 │ App (SwiftUI + RealityKit)   │  ws://:9090     │ rosbridge_server                       │
 │  ├ ROSBridgeClient ◄─────────┼────CBOR/JSON────┼─► /tf /tf_static /joint_states         │
 │  ├ TFKit / URDFKit / FK      │                 │   /robot_description (transient_local) │
 │  ├ RobotModel (RealityKit)   │  http://:8765   │ ar_bridge (rclpy)                      │
 │  ├ MeshProvider ◄────────────┼───OBJ/STL/USDZ──┼─  GET /mesh?uri=package://...          │
 │  ├ LiDARScan → PLY/PCD ──────┼───POST /cloud───┼─► publishes PointCloud2 (latched)      │
 │  ├ AlignmentKit (gizmo,      │                 │   writes <stamp>.pcd/.ply              │
 │  │   AR-world ↔ base_link)   │                 │ robot_state_publisher (ur16e / any)    │
 │  └ AppCore (session state)   │                 │ rviz2, MoveIt2 (octomap from topic)    │
 └──────────────────────────────┘                 └────────────────────────────────────────┘
```

### 3.1 Repository layout

```
MRRosProject/
├── CONTRIBUTING.md                     # conventions, commands, module map
├── docs/  PLAN.md  ARCHITECTURE.md  adr/  protocols/ar_bridge_http.md  testing.md
├── ios/
│   ├── project.yml               # XcodeGen → MRRos.xcodeproj (no pbxproj merge pain)
│   ├── MRRos/                    # thin app target: SwiftUI views, DI, entitlements
│   └── Packages/                 # local SwiftPM packages, each with its own tests
│       ├── ROSBridgeClient       # websocket, rosbridge v2 protocol, JSON+CBOR, reconnect
│       ├── ROSMessages           # Codable std/geometry/sensor/tf2 msgs (+ PointCloud2 layout)
│       ├── TFKit                 # TF buffer, lookup w/ time, static+dynamic, simd
│       ├── URDFKit               # URDF XML → links/joints/visuals; FK
│       ├── RobotModel            # URDF → RealityKit entity tree; joint_states → poses
│       ├── MeshProvider          # package:// → ar_bridge → cached MeshResource
│       ├── LiDARScan             # ARKit depth/mesh → points, voxel filter, PLY/PCD encode
│       ├── ARBridgeTransport     # HTTP client to ar_bridge (chunked upload, retries)
│       ├── AlignmentKit          # gizmo + frame math (ARKit Y-up ↔ ROS Z-up), persistence
│       └── AppCore               # session state machine, settings, OSLog, diagnostics
├── ros2_ws/src/
│   ├── ar_bridge/                # rclpy node: HTTP server, PointCloud2 publisher, mesh server
│   ├── ar_bridge_msgs/           # srv/msg only if std ones don't suffice
│   └── ar_dev_bringup/           # launch: rosbridge + rsp(ur16e) + mock joints + ar_bridge + rviz cfg
└── tools/                        # env setup (micromamba), build/test/lint scripts, fixture recorder
```

Rule: packages depend downward only (`AppCore` → kits → `ROSMessages`); nothing imports the
app target. Pure-Swift packages (`ROSBridgeClient`, `ROSMessages`, `TFKit`, `URDFKit`,
`AlignmentKit`, `LiDARScan` core) must build and test **on macOS** so tests run in seconds
without a simulator.

### 3.2 Key technical points

- **Frames.** ROS: Z-up, X-forward, right-handed. ARKit: Y-up, −Z-forward, right-handed.
  `AlignmentKit` owns the single conversion and the chain
  `arkit_world → T_align → base_link (→ TF → any frame)`. Covered by property tests.
- **robot_description.** Jazzy `robot_state_publisher` publishes `/robot_description`
  (transient_local); rosbridge subscription with latching fallback to the parameter service.
- **Meshes — three tiers, one lookup key.** The key is `(package name, relative mesh path)`
  from the URDF `<mesh filename="package://…">`, plus a content hash when available.
  1. **Bundled**: USDZ meshes for the §3.3 robots, converted offline by
     `tools/meshes/convert.py` (DAE/STL → glTF → USDZ, scale/axis fixed, verified against the
     URDF `scale` attribute) and shipped in an app asset catalog with a manifest
     (`meshes.json`: key → file, sha256, source version). Zero network, instant spawn.
  2. **Cached**: previously fetched meshes in the app's Caches dir, keyed by hash.
  3. **Fetched**: `ar_bridge` resolves `package://` via `ament_index`, converts DAE/STL → OBJ
     (trimesh), returns bytes + hash; app loads via ModelIO → RealityKit and caches.
  Missing mesh → placeholder primitive from `<collision>` geometry, never a crash.
- **Joint motion.** `RobotModel` maps `/joint_states` names → URDF joints (handles tf/joint
  prefixes like `ur_` or `crx_`, multiple publishers, missing joints), applies revolute/
  prismatic/continuous limits, interpolates between messages (`/joint_states` at 10–500 Hz),
  and exposes the same FK used for the M2 `/tf` cross-check.
- **Point cloud.** Accumulate from `ARFrame.sceneDepth` (+confidence) and/or `ARMeshAnchor`
  vertices; voxel-grid downsample on device (Metal or vDSP); encode binary PLY; upload;
  `ar_bridge` republishes as `PointCloud2` in `base_link` (or `map`) with
  `durability=transient_local`, and writes `.pcd`/`.ply`.
### 3.3 Supported robots

| Priority | Robot | Description package (ROS 2 Jazzy) | Visual meshes | Notes |
|---|---|---|---|---|
| 1 | FANUC CRX-30iA | `fanuc_crx_description` (FANUC-CORPORATION/fanuc_description, `main` = Jazzy) | DAE visual, STL collision | Xacro macros with link-length params → we snapshot the expanded URDF as a fixture. |
| 1 | FANUC CRX-20iA/L | same | same | |
| 2 | UR30 | `ur_description` (UniversalRobots/Universal_Robots_ROS2_Description) | DAE visual, STL collision | `ur_type:=ur30` |
| 2 | UR20 | same | same | `ur_type:=ur20` |
| 3 | UR10 / UR10e | same | same | `ur_type:=ur10 / ur10e`; UR16e kept as a fixture since the old app targeted it. |
| — | Any other URDF | from the network | fetched + converted | Tier 3 meshes only; still must spawn and move. |

Both vendors' packages are installed in the dev bringup (`ur_description` from RoboStack;
`fanuc_description` built from source in `ros2_ws`). Each robot gets: an expanded-URDF
fixture, a bundled USDZ mesh set, a mock `/joint_states` publisher profile, and an
FK-vs-`/tf` test. Adding a robot = running the converter + adding a fixture (documented in
`docs/adding-a-robot.md`).

### 3.4 Multi-distro support (Humble · Jazzy · Lyrical)

| Layer | What varies | How we handle it |
|---|---|---|
| iOS app | Nothing: rosbridge protocol v2 and `std/geometry/sensor/tf2_msgs` are identical across the three. | `ar_bridge` `/health` reports `ros_distro`; the app shows it and feature-gates nothing on it. Integration tests run against each distro's bringup. |
| `ar_bridge`, `ar_dev_bringup` (rclpy, launch) | Python 3.10 (Humble) vs 3.12 (Jazzy) vs 3.12+ (Lyrical); minor rclpy/launch API drift. | Code stays Python-3.10-compatible (ruff `target-version = py310`). No distro branches in code; differences go in `ar_dev_bringup/distro.py` behind `ROS_DISTRO` and are tested. |
| Vendor descriptions | `ur_description` is released for all three. `fanuc_description` has `main` (Jazzy/newer) and `humble` branches. | `tools/external.<distro>.repos` pins the branch/commit per distro; `tools/ros-build.sh` picks it from `ROS_DISTRO`. |
| Dev env (macOS) | RoboStack channels `robostack-humble`, `-jazzy`, `-lyrical`, all osx-arm64. | `tools/ros-env.sh create <distro>` renders `tools/ros_env.template.yaml` → env `ros_<distro>`. Jazzy is created by default; the others on demand. |
| MoveIt (M5) | MoveIt 2.5 (Humble) vs 2.12+ (Jazzy/Lyrical): same planning-scene/octomap interfaces, different config packaging. | Octomap updater config kept per distro in `ar_dev_bringup/config/moveit.<distro>.yaml` only if the shared one fails. |
| CI | — | Matrix over `ros:humble`, `ros:jazzy`, `ros:lyrical` containers: lint, pytest, colcon build, launch smoke test. |

Rule: a feature is "done" only when its ROS-side tests pass on all three distros in CI; the macOS
dev loop runs on one at a time.

- **Robustness.** Reconnect with backoff, versioned HTTP protocol, structured OSLog + in-app
  diagnostics/export, feature flags per module, no singletons across packages.

## 4. Milestones (each ends in a runnable, tested demo)

| M | Deliverable | Exit test |
|---|-------------|-----------|
| **M0** Environment | RoboStack env (Jazzy default; Humble/Lyrical creatable with one command) + `ar_dev_bringup` (rosbridge, rsp with selectable robot `robot:=crx30ia|crx20ial|ur30|ur20|ur10e`, mock joints, rviz); `fanuc_description` built from source; GitHub repo; XcodeGen project; package skeletons + CI (`swift test` on macOS, `xcodebuild` sim build); formatter hooks; XcodeBuildMCP wired. | `ros2 launch ar_dev_bringup dev.launch.py robot:=crx30ia` (and `ur30`) shows the robot in RViz; `swift test` green; app runs on device showing "Hello AR". |
| **M1** Connectivity | `ROSBridgeClient` + `ROSMessages`: connect, list topics, subscribe `/tf*`, `/joint_states`, fetch `/robot_description`. Connection screen + live joint readout. | Unit tests on recorded frames; integration test against local rosbridge; app shows joints moving when the mock publisher moves. |
| **M2a** Robot in AR (bundled) | `URDFKit`, `RobotModel`, `MeshProvider` tiers 1–2, `tools/meshes/convert.py`, bundled USDZ for the 5 priority robots. Spawn at a tapped anchor, animate from `/joint_states`. | FK vs `/tf` from rsp within 1e-4 m for all 5 robots (automated); each renders with correct meshes and moves with the mock joint publisher. |
| **M2b** Robot in AR (any URDF) | `ar_bridge` mesh endpoint, `MeshProvider` tier 3, placeholder geometry fallback. | A robot not in the bundle (e.g. UR16e, or a CRX with a tool attached) spawns from the network alone. |
| **M3** Scan → RViz | `LiDARScan`, `ARBridgeTransport`, `ar_bridge` cloud endpoint. Scan, preview, export, upload; `PointCloud2` in RViz; file on disk. | PLY encode/decode roundtrip; voxel filter tests; 1M-point upload < 5 s on Wi-Fi; cloud visible in RViz. |
| **M4** Alignment | `AlignmentKit` gizmo; clouds published in `base_link`; overlay check view; save/restore alignment (ARWorldMap). | Frame-math property tests; manual checklist: virtual UR overlays real UR; cloud of a box placed at a measured offset appears at that offset in RViz. |
| **M5** Planning scene | MoveIt2 octomap from the latched cloud (or PlanningScene diff service in `ar_bridge`); clear/update controls in app. Split (2026-11-18): **M5a** backend research + MoveIt on the Mac ✅, **M5b** in-AR preview, robot self-filter, crop + exclusion boxes ✅, **M5c** below. | MoveIt plans around a scanned obstacle in RViz. ✅ (M5a) |
| **M5c** Scenes + adapters | (1) MoveIt late join: `ar_bridge` clears + re-publishes the last scan whenever `move_group` (re)appears. (2) **Saved scenes**: a scene = raw points (+ mesh after 3), crop/exclusion boxes, robot model and the **joint angles at scan time** (the robot filter must use those — the scan contains the real robot in that pose), name/date; stored in **base_link** so it survives re-placement and uploads without AR. New `SceneLibrary` package (format + conversions). App: Scenes list (save, load = replace current scan, upload without loading, rename, delete); files in Documents (Files app/AirDrop). `ar_bridge` keeps a scene library too (same PLY + JSON format; list/get/put/delete/publish over HTTP), so scenes move app ↔ ROS machine. (3) Mesh upload: ARKit mesh, filtered on the phone, → MoveIt `CollisionObject` in base_link (the input cuMotion uses); scenes include it. (4) GPU spike (x86 first, Thor later; Isaac ROS 4.x = Jazzy): cuMotion with our mesh, then nvblox from streamed depth frames. | (1) Upload, then start/restart MoveIt: obstacle present, plans avoid it. (2) Save, kill app, re-place robot, load: overlays correctly; upload from list without placing = same cloud in RViz; a scene pushed to and pulled from `ar_bridge` round-trips. (3) MoveIt plans around a scanned box sent as a mesh (UR + CRX). (4) Written decision: mesh, depth streaming, or both. |
| **M6** Markers + lab | AprilTag/ArUco auto-alignment (OpenCV), persistence polish, integration with lab PC + real UR16e via `ur_robot_driver`. | End-to-end on real robot; distro/IP confirmed. |

Each milestone: branch → PR → `/code-review` → merge; CHANGELOG entry; `docs/testing.md` checklist updated.

## 5. Testing strategy

- **Unit (fast, macOS):** every pure package; fixtures in `Tests/Fixtures` (recorded rosbridge
  frames, `ur16e.urdf`, small PLYs).
- **Integration (Mac):** `tools/it.sh` launches `ar_dev_bringup` headless and runs the
  `ROSBridgeClient`/`ARBridgeTransport` integration suites against it.
- **ROS side:** `pytest` + `launch_testing` for `ar_bridge`; `ros2 bag` fixtures.
- **Device (manual, scripted):** per-milestone checklists in `docs/testing.md`; in-app
  diagnostics screen + log export so failures are reportable.
- **CI:** GitHub Actions macOS runner: `swift test`, simulator build, lint. ROS tests on an
  Ubuntu runner with `ros:jazzy`.

## 6. Development tooling

- **`CONTRIBUTING.md`**: module map, build/test commands, conventions (Swift 6 strict concurrency,
  no force-unwraps in packages, ROS naming), "how to add a module" recipe.
  (rclpy/launch/MoveIt), `qa-reviewer` (test coverage + `/code-review`), `docs-writer`.
  (`swift test` for all packages), `/ios-build` (XcodeGen + sim build), `/device-run`
  (build & launch on the paired iPhone via XcodeBuildMCP), `/it` (integration suite),
  `/new-module` (scaffold a package with tests + conventions entry).
- **Hooks**: SwiftFormat/SwiftLint on edit of `*.swift`; `ruff` on `*.py`.
- **MCP**: XcodeBuildMCP (`npx xcodebuildmcp@latest`) for
  build/run/test/screenshots on simulator and device (code signing configured once in Xcode).
- **Tools to install**: micromamba + RoboStack Jazzy (`ros-jazzy-desktop`, `rosbridge-suite`,
  `ur-description`, `moveit`, `robot-state-publisher`, `joint-state-publisher-gui`),
  `xcodegen`, `swiftlint`, `swiftformat`, Node (for XcodeBuildMCP), `uv`/`ruff`.

## 7. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| RoboStack gaps on macOS (MoveIt plugins, rviz quirks, newer Lyrical packages missing) | Verify in M0; CI on Linux containers is the source of truth for all three distros; Docker fallback for anything RoboStack lacks. |
| Distro drift (Python 3.10 vs 3.12, launch/rclpy API, `fanuc_description` branch per distro) | py310-compatible code, per-distro `.repos` pins, 3-distro CI matrix gating every PR. |
| rosbridge throughput for `/tf` at 100 Hz+ | CBOR, throttle_rate, queue_length; only needed frames. |
| Runtime mesh formats on iOS (no DAE) | Offline DAE→USDZ bundle for priority robots; server-side DAE/STL→OBJ with hash cache for the rest. |
| Mesh scale/axis mismatches (DAE unit/up-axis, URDF `scale`) | Converter normalizes to metres/Y-up and records the applied transform; M2a FK/visual check per robot catches errors. |
| FANUC xacro drift (link-length params, tool flanges) | Snapshot expanded URDFs as fixtures per upstream tag; network URDF always wins at runtime. |
| ARKit drift during long scans | Chunked scans, confidence filtering, ARWorldMap relocalization, re-align step. |
| Frame convention bugs | Single conversion point + property tests + RViz cross-check in M2/M4. |
| Device code signing / entitlements | One-time setup in Xcode; documented in `docs/testing.md`. |

## 8. Next step

On approval: execute **M0** (environment + scaffolding), then review together before M1.
