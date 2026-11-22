# Third-party notices

MRRos's own code is MIT-licensed (see [`LICENSE`](LICENSE)). The repository also contains files
derived from third-party robot descriptions. **Those files keep their original licenses, which the
MIT license does not override.** They are listed here with what was changed.

## Bundled robot meshes (`ios/MRRos/Meshes/`)

The app ships visual meshes for five robots so they render without a network connection. Each was
converted from the upstream COLLADA (`.dae`) file to USDZ by `tools/meshes/convert.py`. Geometry
and textures are unchanged apart from unit/axis normalization (metres, Y-up). The source version
of every file is recorded in [`ios/MRRos/Meshes/meshes.json`](ios/MRRos/Meshes/meshes.json).

| Files | Source | License |
|---|---|---|
| `fanuc_crx_description/meshes/crx30ia/`, `crx20ia_l/` | [FANUC-CORPORATION/fanuc_description](https://github.com/FANUC-CORPORATION/fanuc_description) | Apache-2.0, [`ios/MRRos/Meshes/fanuc_crx_description/LICENSE`](ios/MRRos/Meshes/fanuc_crx_description/LICENSE) |
| `ur_description/meshes/ur10e/` | [UniversalRobots/Universal_Robots_ROS2_Description](https://github.com/UniversalRobots/Universal_Robots_ROS2_Description) 3.5.1 | BSD-3-Clause, [`ios/MRRos/Meshes/ur_description/LICENSE`](ios/MRRos/Meshes/ur_description/LICENSE) |
| `ur_description/meshes/ur20/`, `ur30/` | same, 3.5.1 | Universal Robots A/S' Terms and Conditions for Use of Graphical Documentation, in each folder's `LICENSE.txt` |

**UR20 and UR30 meshes.** © 2023 Universal Robots A/S. Use hereof is subject to Universal Robots
A/S' Terms and Conditions for Use of Graphical Documentation. Those terms ship next to the files
(`LICENSE.txt`) as they require, and they apply to anyone who downloads or uses them. In short,
they permit use for simulation, visualization, path planning and collision avoidance of Universal
Robots' products, and non-commercial research use; they do not permit using the meshes to build a
competing product. Read the full text before using these files. The notice embedded in the
original files was dropped by the conversion and has been written back into each USDZ's metadata
(`tools/meshes/stamp_notice.py`).

## Test fixtures

| Files | Derived from | License |
|---|---|---|
| `ios/Packages/URDFKit/Tests/Fixtures/{crx30ia,crx20ial}/robot.urdf` | xacro output of `fanuc_crx_description` | Apache-2.0 (as above) |
| `ios/Packages/URDFKit/Tests/Fixtures/{ur10e,ur20,ur30}/robot.urdf` | xacro output of `ur_description` | BSD-3-Clause (as above) |
| `ios/Packages/ROSBridgeClient/Tests/Fixtures/*.json` | recorded rosbridge traffic containing such a URDF | as the URDF they contain |

Paths in the xacro-generated header comments were replaced with placeholders; nothing else changed.

## Not bundled

Everything else (ROS 2, MoveIt, rosbridge, `ur_description`, `fanuc_description`,
`fanuc_driver`) is installed or cloned at build time under its own license and is not part of this
repository.

## Trademarks

FANUC, CRX, Universal Robots, UR and the robot model names are trademarks of their respective
owners. This project is not affiliated with or endorsed by them.
