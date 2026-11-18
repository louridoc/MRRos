# M5a — How planning backends ingest scene data

Date: 2026-11-18. Purpose: pick M5b/M5c designs on facts. Each claim is marked
**[verified]** (run on the Mac in this project) or **[docs]** (vendor documentation/source, not
run — cuRobo/nvblox need an NVIDIA GPU, which the Mac doesn't have).

## 1. MoveIt 2 — point-cloud octomap updater

How it works (`moveit_ros_perception`, `PointCloudOctomapUpdater`; read in source **[docs]**,
behaviour then confirmed **[verified]** with `tools/moveit_scene_check.py`):

- Subscribes to a `PointCloud2` topic (ours: `/mrros/static_cloud`, config
  `ar_dev_bringup/config/sensors_3d.yaml`) and inserts points into the octomap.
- **Ray clearing from the cloud's frame origin** (for us: `base_link`). Every voxel a point
  occupies is removed from the free set first ("mark free cells only if not seen occupied in this
  cloud"), so **one complete cloud cannot erase its own obstacles**. A later *partial* cloud would
  clear earlier obstacles along its rays — the app always uploads the whole scan, so keep it that
  way.
- **Self-filtering**: points inside the robot's collision geometry at its current TF pose (+
  `padding_offset`) are dropped. [verified] with points sampled on the real collision meshes of
  UR10e and CRX-30iA.
- The octomap **accumulates** across clouds; `/clear_octomap` (std_srvs/Empty) resets it.

Findings that shape M5c **[verified]**:

1. **A MoveIt started after an upload never sees that upload.** The updater's subscription doesn't
   get the latched (`TRANSIENT_LOCAL`) message; re-publishing made the obstacle appear at once.
2. ~~A cloud arriving in move_group's first seconds is silently not self-filtered.~~ **Root cause
   found and fixed (2026-11-18):** the self-filter looks up every robot link's TF at the cloud's
   *exact* stamp; ar_bridge stamped it "now", often a few ms newer than the last 30 Hz joint TF, so
   lookups failed ("shape_mask: Missing transform") and those links weren't filtered — at startup
   always, later intermittently. ar_bridge now stamps the static cloud **0 = latest transform**
   (the robot doesn't move during a scan). Verified: 9/9 runs on CRX + UR with no settle wait,
   including right after startup, zero missing-transform errors.
3. ⇒ `ar_bridge` should **clear the octomap, then publish** on every upload and again whenever
   move_group (re)appears (finding 1). The periodic refresh is no longer needed for finding 2.

End-to-end result **[verified]**, both priority vendors: a wall uploaded through ar_bridge's HTTP
endpoint (the app's path) makes the blocked configuration invalid, the robot's own surface points
are filtered, and OMPL plans around the wall with every waypoint collision-free — UR10e (2/2 runs)
and CRX-30iA (3/3 runs). This is the M5 exit test, automated:

```
tools/ros.sh jazzy ros2 launch ar_dev_bringup dev.launch.py robot:=ur10e moveit:=true
tools/ros.sh jazzy python tools/moveit_scene_check.py --robot ur10e
# CRX is upright at zero; start it reaching out:  ... robot:=crx30ia positions:="0,0.7,0,0,0,0"
```

## 2. NVIDIA nvblox (Isaac ROS) [docs]

- Builds a TSDF/ESDF (+ mesh) from **depth images + camera intrinsics + pose** — topics
  `camera_{i}/depth/image` (float m or uint16 mm) with `camera_{i}/depth/camera_info`, up to 4
  cameras; pose from TF or `transform`/`pose` topics.
- Also accepts `pointcloud` (`PointCloud2`) but as **3D LiDAR sweeps with LiDAR intrinsics set** —
  it converts the cloud back into a depth image, so it expects a scanning sensor, not an
  arbitrary fused cloud like ours.
- Map services: `~/save_map`, `~/load_map` (full serialized map), `~/save_ply` (mesh).
- ⇒ The natural iPhone→nvblox path is **streaming depth frames** (ARKit `sceneDepth` +
  intrinsics + pose, expressed via the M4 alignment), or **`load_map`** of a map built elsewhere —
  not our `/mrros/static_cloud`. Needs an M5c spike on GPU hardware.

## 3. cuRobo / Isaac ROS cuMotion [docs]

- cuRobo's world (`WorldConfig`): **cuboids, meshes, and nvblox maps**; collision checkers stack
  (nvblox ⊃ mesh ⊃ cuboid). Cuboids are ~4× faster to check than meshes.
- cuMotion is exposed to MoveIt 2 as a planner plugin (`isaac_ros_cumotion_moveit`); obstacles
  come from MoveIt collision objects (cuboids/meshes) and/or an nvblox ESDF
  (`/nvblox_node/get_esdf_and_gradient`). It ships a node that segments the robot out of depth
  images using its joint state.
- ⇒ Our scan reaches cuRobo either as a **mesh** (ARKit's reconstruction → MoveIt
  CollisionObject) or **via nvblox** (depth frames). A raw point cloud is not a native input.

## 4. Platforms [docs]

- Isaac ROS **4.x → ROS 2 Jazzy**, on Jetson **Thor** (JetPack 7) and x86 + NVIDIA GPU.
- Isaac ROS **3.2 → Humble** remained the path for Jetson Orin.
- Our ROS side is pure Python and arch-independent; target Jazzy for GPU machines.

## 5. Environment findings on the Mac [verified]

- MoveIt, `ur_moveit_config` are on RoboStack for Humble/Jazzy/Lyrical. **`moveit_ros_perception`
  is not pulled in by the `moveit` package** — without it the updater plugin silently doesn't
  exist ("Declared types are" empty). Added to `tools/ros_env.template.yaml`.
- `fanuc_moveit_config` (SRDFs for crx30ia, crx20ia_l, …) is built from FANUC's `fanuc_driver`
  repo, pinned per distro in `tools/external.repos.tsv`; only that package is built. Its config has
  two problems handled in `moveit.launch.py`: OMPL settings keyed to group `arm` while the SRDF
  group is `manipulator` (so they never apply), and Ruckig smoothing failing under its 0.4 rad/s²
  limits. It also references an `end_effector` link the description package names `ee_link`
  (harmless warnings).
- **macOS application firewall**: a new ROS executable (here `move_group`) silently can't receive
  DDS traffic until allowed — others discover it, it discovers no one. Fix once per binary:
  `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <path> --unblockapp <path>`.
  (Ruled out on the way: RMW mismatch, process context, UDP message size.)

## 6. Recommendations

- **M5b** (in-app): keep the self-filter on the phone too (preview, and for non-MoveIt backends),
  plus crop/delete edits — MoveIt's filter is necessary but has the startup blind spot above.
- **M5c** (adapters): (a) MoveIt — ar_bridge does clear-then-publish on upload and on
  move_group (re)appearing; (b) cuRobo/nvblox — spike on the GPU machine: mesh upload →
  CollisionObject, and/or depth-frame streaming into nvblox.
