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
(filled when M1 starts)
