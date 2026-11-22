# MRRos

An iPhone/iPad app (LiDAR, iOS 18+) that joins a **ROS 2** network to:

- **show the robot in augmented reality.** The app builds the robot from `robot_description`,
  animates it from `/joint_states`, and lets you align it with the real robot;
- **scan the room into the robot's planning scene.** The LiDAR scan is sent as a point cloud
  (MoveIt octomap) and/or a triangle mesh (MoveIt collision object), expressed in the robot's
  `base_link`;
- **clean the scan before it reaches the planner.** The real robot is filtered out automatically,
  and you can crop the scan to the workspace and draw exclusion boxes;
- **save scenes** so you can send them to the robot later without re-scanning, on the phone or in
  a library on the ROS machine.

Supported robots out of the box: FANUC CRX-30iA and CRX-20iA/L, Universal Robots UR10e, UR20 and
UR30. Other robots work too: their meshes are served by the companion node. ROS 2 Humble, Jazzy
and Lyrical.

> **Status: research prototype.** Developed and tested on macOS (Apple Silicon) with ROS 2 Jazzy
> through RoboStack and an iPhone with LiDAR. The app never commands the robot. Read
> [SECURITY.md](SECURITY.md) before using it near real hardware.

## How it works

```
 iPhone / iPad (MRRos app)                         ROS 2 machine
 ┌──────────────────────────┐   WebSocket :9090   ┌─────────────────────────────────────┐
 │ robot in AR, alignment   │◄───────────────────►│ rosbridge_server                    │
 │ LiDAR scan + filters     │                     │ robot_state_publisher, /joint_states│
 │ saved scenes             │   HTTP :8765        │ ar_bridge (this repo)               │
 │                          │────────────────────►│  → /mrros/static_cloud (PointCloud2)│
 └──────────────────────────┘                     │  → MoveIt collision object (mesh)   │
                                                  │  → scene library, mesh serving      │
                                                  │ MoveIt (optional)                   │
                                                  └─────────────────────────────────────┘
```

- **rosbridge** carries ROS topics to the app: the robot description and joint states.
- **ar_bridge** is this repo's companion node. Over plain HTTP it takes the uploaded scan and
  publishes it to MoveIt, serves robot meshes the app doesn't bundle, and keeps the scene library.

## Requirements

| Side | You need |
|---|---|
| Device | iPhone or iPad **with LiDAR** (Pro models), iOS 18 or later |
| App build | A Mac with Xcode (recent; the project targets Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen), an Apple ID (a free personal team works for your own devices) |
| ROS side | ROS 2 Humble, Jazzy or Lyrical, either on **Ubuntu** (native install) or on **macOS** via [RoboStack](https://robostack.github.io) |
| Network | Phone and ROS machine on the same trusted network |

## 1. Set up the ROS side

Clone the repository first:

```sh
git clone https://github.com/louridoc/MRRos.git
cd MRRos
```

### Option A: macOS (RoboStack, the tested path)

```sh
brew install micromamba uv
tools/ros-env.sh create jazzy     # one-time: creates the ros_jazzy env with ROS 2 + MoveIt (takes a while)
tools/ros-build.sh jazzy          # fetches the FANUC sources and builds this repo's packages
tools/ros.sh jazzy ros2 launch ar_dev_bringup dev.launch.py robot:=ur10e
```

`tools/ros.sh jazzy <command>` runs anything inside that environment. On macOS, the first time a
new ROS program runs, **allow it in the macOS firewall** (see Troubleshooting).

### Option B: Ubuntu with a native ROS 2 install

With [ROS 2 installed](https://docs.ros.org/en/jazzy/Installation.html) (Jazzy on Ubuntu 24.04,
Humble on 22.04):

```sh
sudo apt install python3-colcon-common-extensions python3-rosdep
source /opt/ros/jazzy/setup.bash
tools/fetch-external.sh jazzy                 # FANUC description + MoveIt config sources
cd ros2_ws
sudo rosdep init 2>/dev/null; rosdep update
PIP_BREAK_SYSTEM_PACKAGES=1 rosdep install --from-paths src --ignore-src -y
colcon build --symlink-install --packages-up-to ar_dev_bringup ar_bridge
source install/setup.bash
ros2 launch ar_dev_bringup dev.launch.py robot:=ur10e
```

These steps mirror the repository's CI workflow, but they have not yet been run on a physical
Ubuntu machine. Please open an issue if something is missing. `PIP_BREAK_SYSTEM_PACKAGES=1` lets
rosdep install the one pip-only dependency (`trimesh`, for mesh serving) on Ubuntu 24.04.

**Humble (Ubuntu 22.04):** recent `trimesh` releases don't work with its numpy 1.21. After rosdep,
run `pip install "trimesh<4.5"`.

### What the dev bringup starts

`ar_dev_bringup` gives you a complete test setup without a real robot:

- `robot_state_publisher` for the chosen robot: `robot:=crx30ia`, `crx20ial`, `ur10e`, `ur20`,
  `ur30` (meshes bundled in the app) or `ur10`, `ur16e` (meshes served by ar_bridge);
- simulated joint states (`frozen:=true positions:="0,-1.2,1.0,0,0,0"` holds a fixed pose, for
  example to match your real robot);
- rosbridge on **:9090**, ar_bridge on **:8765**, and RViz (`rviz:=false` for headless);
- with `moveit:=true`, MoveIt as well: the scan becomes its octomap, the mesh a collision object,
  and **Plan & Execute** moves the simulated robot.

## 2. Build the app

```sh
brew install xcodegen
```

Signing needs two values. Put them in `~/.mrros/config`, which lives outside the repository:

```sh
mkdir -p ~/.mrros && cat >> ~/.mrros/config <<'EOF'
DEVELOPMENT_TEAM=XXXXXXXXXX              # Xcode > Settings > Accounts > your team (10 characters)
MRROS_BUNDLE_ID=io.github.yourname.mrros # must be unique to your team
EOF
```

Then generate the project and open it:

```sh
tools/xcodegen.sh
open ios/MRRos.xcodeproj
```

In Xcode, choose your iPhone or iPad as the run destination and press **Run**. The first time,
iOS asks you to trust the developer (Settings > General > VPN & Device Management) and, inside
the app, to allow **Local Network** access. Allow it, or the app can't reach ROS.

Without a team you can still run the package tests (`tools/ios-test.sh`) and a simulator build
(`tools/ios-build.sh`). ARKit and LiDAR need a real device.

## 3. First run

1. **Connect.** Tap the status pill at the top and enter the ROS machine's IP address (rosbridge
   port 9090). The pill turns green and the app receives the robot description; the joints
   button next to the pill shows live joint values.
2. **Place the robot** (Robot tab). Point the crosshair at the floor where the real robot's base
   is and tap **Place**.
3. **Align.** Tap **Align**, pick an axis (X, Y, Z or Rotate Z) and drag along its arrow until
   the virtual robot overlays the real one. Tap **Done**: the alignment is saved and can be
   restored in a later session.
4. **Scan** (Scan tab). Walk around and tap **Capture**. Points on the robot show red and are never
   uploaded. Optionally:
   - turn on **Crop** to keep only the workspace;
   - add **exclusion boxes** for things that aren't obstacles (they show orange);
   - use **Edit** to move or resize the boxes.
5. **Upload.** Tap the upload button and choose **points**, a **mesh** or **both**. In RViz the
   cloud appears on `/mrros/static_cloud`; with MoveIt, the mesh appears as the collision object
   `mrros_scan_mesh`.
6. **Save the scene** with the folder button, to load it later, upload it again without scanning,
   or copy it to the ROS machine.

**Clear** empties the scan on the phone and on the ROS side.

## Using MRRos in your own ROS workspace

You don't need the dev bringup. On your robot's ROS machine you need:

| Needed | Why |
|---|---|
| `rosbridge_server` (port 9090) | the app's connection to ROS |
| `/robot_description` (latched, as `robot_state_publisher` publishes it) and `/joint_states` | to build and animate the robot |
| `ar_bridge` from this repo | uploads, mesh serving, scene library |
| the robot's description package (meshes) | only for robots not bundled in the app |
| MoveIt with the point-cloud octomap updater (`moveit_ros_perception`) | only if you want the scan in planning |

Build `ar_bridge` into your workspace (copy or symlink `ros2_ws/src/ar_bridge`), then:

```sh
ros2 launch rosbridge_server rosbridge_websocket_launch.xml
ros2 launch ar_bridge ar_bridge.launch.py                       # defaults
ros2 launch ar_bridge ar_bridge.launch.py scenes_dir:=/data/scenes http_port:=8765
ros2 launch ar_bridge ar_bridge.launch.py params_file:=/path/to/my_ar_bridge.yaml
```

Every setting is documented in
[`ros2_ws/src/ar_bridge/config/ar_bridge.yaml`](ros2_ws/src/ar_bridge/config/ar_bridge.yaml). For
MoveIt's octomap, see the sensor configuration in
[`ar_dev_bringup/config/sensors_3d.yaml`](ros2_ws/src/ar_dev_bringup/config/sensors_3d.yaml). Data
is stored under `~/.mrros/`: uploaded clouds in `clouds/`, saved scenes in `scenes/`.

The app ↔ ar_bridge protocol is in
[`docs/protocols/ar_bridge_http.md`](docs/protocols/ar_bridge_http.md), and the saved-scene
format in [`docs/protocols/scene_format.md`](docs/protocols/scene_format.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| macOS: a ROS program (e.g. `move_group`) runs, but no other node sees its data | The macOS application firewall blocks new binaries silently. Allow it once: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <path> --unblockapp <path>` (path from `which move_group` inside the env). |
| The app can't connect | Same network? IP correct? Port 9090 open? On the phone: Settings > Privacy & Security > Local Network > MRRos must be on. |
| Connected, but no robot to place | Is `/robot_description` published? (`ros2 topic echo --once /robot_description`) |
| Upload fails with "not implemented" (501) | ar_bridge is older than the app: rebuild the ROS workspace and restart it. Mesh upload also needs MoveIt's message packages on the ROS machine. |
| MoveIt says the start state is in collision after a mesh upload | Part of the real robot is still in the mesh. Check the alignment and re-upload; points on the robot should show red before uploading. |
| Signing errors in Xcode | Check `DEVELOPMENT_TEAM` and that `MRROS_BUNDLE_ID` is unique to your team, then run `tools/xcodegen.sh` again. |

## Documentation

- [`CONTRIBUTING.md`](CONTRIBUTING.md): developer reference (layout, commands, conventions, tests).
- [`docs/PLAN.md`](docs/PLAN.md): architecture, design decisions and milestones.
- [`docs/testing.md`](docs/testing.md): test checklists and findings per milestone.
- [`docs/adding-a-robot.md`](docs/adding-a-robot.md): bundling a new robot's meshes.
- [`SECURITY.md`](SECURITY.md): network security and robot safety.

## License

MRRos is released under the [MIT License](LICENSE). The bundled robot meshes and the test
fixtures derived from robot descriptions keep their own licenses (Apache-2.0, BSD-3-Clause, and
Universal Robots' graphical-documentation terms for the UR20/UR30 meshes). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

FANUC, CRX, Universal Robots and UR are trademarks of their respective owners. This project is
not affiliated with or endorsed by them.

## Acknowledgements

Built on [ROS 2](https://ros.org), [MoveIt](https://moveit.ai),
[rosbridge_suite](https://github.com/RobotWebTools/rosbridge_suite),
[RoboStack](https://robostack.github.io), Universal Robots'
[ROS 2 description](https://github.com/UniversalRobots/Universal_Robots_ROS2_Description) and
FANUC's [fanuc_description](https://github.com/FANUC-CORPORATION/fanuc_description).
