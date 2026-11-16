# MRRos

iPhone (LiDAR) augmented-reality app that joins a ROS 2 network to scan the environment into a
manipulator's planning scene and align a virtual robot (FANUC CRX, Universal Robots) with the real one.

- Plan, decisions and milestones: [`docs/PLAN.md`](docs/PLAN.md)
- Developer conventions and commands: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- App ↔ node protocol: [`docs/protocols/ar_bridge_http.md`](docs/protocols/ar_bridge_http.md)
- Test checklists: [`docs/testing.md`](docs/testing.md)

## Quick start (macOS, Apple Silicon)

```sh
brew install micromamba xcodegen swiftlint swiftformat node uv
tools/ros-env.sh create jazzy        # or humble / lyrical
tools/ros-build.sh jazzy
tools/ros.sh jazzy ros2 launch ar_dev_bringup dev.launch.py robot:=crx30ia
tools/ios-test.sh                    # Swift package tests
tools/ios-build.sh                   # simulator build; open ios/MRRos.xcodeproj for device runs
```

Supported ROS 2 distros: Humble, Jazzy, Lyrical (CI matrix). Supported robots: see `docs/PLAN.md` §3.3.
