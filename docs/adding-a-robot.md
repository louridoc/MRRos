# Adding a robot

1. **Description package**: make it available for every supported distro — a RoboStack package
   in `tools/ros_env.template.yaml` (`ros-{{DISTRO}}-…`) or a source clone pinned per distro in
   `tools/external.repos.tsv`.
2. **Catalog**: add a `RobotSpec` to `ros2_ws/src/ar_dev_bringup/ar_dev_bringup/robots.py`
   (xacro path, args, joint names). `tools/ros.sh jazzy ros2 launch ar_dev_bringup dev.launch.py
   robot:=<key>` must show it in RViz; add the key to the CI smoke-test loop.
3. **Fixture** (M2a): `tools/meshes/snapshot.sh <key>` expands the URDF into
   `ios/Packages/URDFKit/Tests/Fixtures/<key>.urdf` and records the upstream version.
4. **Bundled meshes** (M2a): `tools/meshes/convert.py <key>` → USDZ files + `meshes.json`
   manifest entry in the app bundle.
5. **FK test** (M2a): add `<key>` to the FK-vs-`/tf` parametrized test.
6. Add the row to `docs/PLAN.md` §3.3.
