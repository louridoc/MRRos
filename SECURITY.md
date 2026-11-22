# Security and safety

## Run it on a trusted network only

MRRos is a research tool. Its network services have **no authentication and no encryption**:

- **rosbridge** (default port 9090) exposes the ROS graph: anyone who can reach it can read and
  publish topics and call services.
- **ar_bridge** (default port 8765) listens on all interfaces. Anyone who can reach it can upload
  point clouds and meshes that MoveIt will treat as the scene, clear the scene, and read, write
  and delete saved scenes under `scenes_dir`. Scene IDs and file names are validated so requests
  can't leave that folder, but there is no access control.

Use them on a lab or home network you trust, or behind a VPN or firewall. Do not expose these
ports to the internet.

## Robot safety

- The app **never commands the robot**. It reads `/joint_states` and `/robot_description` and
  publishes scene data. The only motion in this repository is the dev bringup's simulated
  controller (`mock_joints`), which moves nothing physical.
- If you connect MoveIt to a real robot, the scene this app sends influences planning:
  - **Excluded regions are free space to MoveIt.** Anything inside an exclusion box, or outside
    the crop box, is removed from the scan, so the planner will happily move through it. Only
    exclude things that really aren't obstacles.
  - **Meshes are not self-filtered by MoveIt.** For mesh uploads, removing the robot's own
    surfaces relies on the app's robot filter and on a correct alignment. Check the result in RViz
    before planning.
  - A scan is a snapshot. People and objects that moved since are not in it.
- Always follow your robot's safety procedures: reduced speed, an enabling device and a clear
  workcell when executing plans.

## Reporting a vulnerability

Please report security issues privately through GitHub's **"Report a vulnerability"** (Security
tab of the repository) rather than in a public issue.
