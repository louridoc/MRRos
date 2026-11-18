"""M5 check: does a scan uploaded through ar_bridge end up as an obstacle MoveIt plans around?

Needs dev.launch.py + moveit.launch.py running for the same robot (UR or CRX). Uploads, via
ar_bridge's real HTTP endpoint (same path the app uses), a wall of points across the arm's
base-joint sweep plus points sampled on the SURFACE of the robot's own collision meshes at its
current pose — what a real LiDAR scan of the robot looks like — then checks:

  1. the sweep's halfway configuration goes from valid → in collision   (cloud reached MoveIt)
  2. the start configuration stays valid                                 (robot filtered out)
  3. MoveIt finds a plan to the goal and every waypoint is collision-free

  tools/ros.sh jazzy python tools/moveit_scene_check.py --robot ur10e --ar-bridge http://localhost:8766

Needs trimesh (in the dev env) to load the collision meshes.

Exit status 0 only if all three hold.
"""

import argparse
import math
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

import numpy as np
import rclpy
import trimesh
from ament_index_python.packages import get_package_share_directory
from moveit_msgs.msg import Constraints, JointConstraint, MotionPlanRequest, RobotState
from moveit_msgs.srv import GetMotionPlan, GetStateValidity
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import JointState
from std_msgs.msg import String
from std_srvs.srv import Empty
from tf2_ros import Buffer, TransformListener

sys.path.insert(0, "ros2_ws/src/ar_bridge")
sys.path.insert(0, "ros2_ws/src/ar_dev_bringup")
from ar_bridge import ply  # noqa: E402
from ar_dev_bringup.robots import ROBOTS  # noqa: E402


class Check(Node):
    def __init__(self, spec):
        super().__init__("moveit_scene_check")
        self.spec = spec
        self.joints: JointState | None = None
        self.create_subscription(JointState, "/joint_states", self._js, 10)
        self.urdf: str | None = None
        latched = QoSProfile(
            depth=1,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            reliability=ReliabilityPolicy.RELIABLE,
        )
        self.create_subscription(
            String, "/robot_description", lambda m: setattr(self, "urdf", m.data), latched
        )
        self.tf = Buffer()
        self.tf_listener = TransformListener(self.tf, self)
        self.validity = self.create_client(GetStateValidity, "/check_state_validity")
        self.planner = self.create_client(GetMotionPlan, "/plan_kinematic_path")
        self.clear = self.create_client(Empty, "/clear_octomap")

    def _js(self, msg):
        self.joints = msg

    def wait(self, pred, timeout, what):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            rclpy.spin_once(self, timeout_sec=0.1)
            if pred():
                return
        raise TimeoutError(what)

    def call(self, client, req, timeout=30.0):
        fut = client.call_async(req)
        self.wait(fut.done, timeout, f"{client.srv_name} call")
        return fut.result()

    def state(self, positions: dict[str, float]) -> RobotState:
        rs = RobotState()
        rs.joint_state.name = list(positions)
        rs.joint_state.position = list(positions.values())
        return rs

    def valid(self, positions) -> bool:
        req = GetStateValidity.Request()
        req.robot_state = self.state(positions)
        req.group_name = self.spec.planning_group
        return self.call(self.validity, req).valid

    def link_pose(self, link) -> np.ndarray:
        t = self.tf.lookup_transform("base_link", link, rclpy.time.Time()).transform
        q, p = t.rotation, t.translation
        m = np.eye(4)
        m[:3, :3] = _quat_matrix(q.x, q.y, q.z, q.w)
        m[:3, 3] = (p.x, p.y, p.z)
        return m


def _quat_matrix(x, y, z, w) -> np.ndarray:
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def _origin_matrix(el) -> np.ndarray:
    m = np.eye(4)
    o = el.find("origin") if el is not None else None
    if o is None:
        return m
    xyz = [float(v) for v in o.get("xyz", "0 0 0").split()]
    r, p, y = (float(v) for v in o.get("rpy", "0 0 0").split())
    cr, sr, cp, sp, cy, sy = (
        math.cos(r),
        math.sin(r),
        math.cos(p),
        math.sin(p),
        math.cos(y),
        math.sin(y),
    )
    m[:3, :3] = [
        [cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr],
        [sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr],
        [-sp, cp * sr, cp * cr],
    ]
    m[:3, 3] = xyz
    return m


def _geometry_mesh(geom) -> trimesh.Trimesh | None:
    if (mesh := geom.find("mesh")) is not None:
        uri = mesh.get("filename")
        if uri.startswith("package://"):
            pkg, _, rel = uri[len("package://") :].partition("/")
            path = f"{get_package_share_directory(pkg)}/{rel}"
        else:
            path = uri.removeprefix("file://")
        loaded = trimesh.load(path, force="mesh")
        scale = [float(v) for v in mesh.get("scale", "1 1 1").split()]
        loaded.apply_scale(scale)
        return loaded
    if (box := geom.find("box")) is not None:
        return trimesh.creation.box(extents=[float(v) for v in box.get("size").split()])
    if (cyl := geom.find("cylinder")) is not None:
        return trimesh.creation.cylinder(float(cyl.get("radius")), float(cyl.get("length")))
    if (sph := geom.find("sphere")) is not None:
        return trimesh.creation.icosphere(radius=float(sph.get("radius")))
    return None


def robot_surface_points(node: Check, per_link: int = 60) -> np.ndarray:
    """Points on the robot's collision surfaces at its current TF pose, in base_link."""
    pts = []
    for link in ET.fromstring(node.urdf).findall("link"):
        for col in link.findall("collision"):
            mesh = _geometry_mesh(col.find("geometry"))
            if mesh is None or not node.tf.can_transform(
                "base_link", link.get("name"), rclpy.time.Time()
            ):
                continue
            surface, _ = trimesh.sample.sample_surface(mesh, per_link, seed=0)
            world = node.link_pose(link.get("name")) @ _origin_matrix(col)
            pts.append((world[:3, :3] @ surface.T).T + world[:3, 3])
    return np.concatenate(pts)


def wall(arm_az: float) -> np.ndarray:
    # Vertical half-plane through the base axis at arm_az + 45°, r in [0.5, 1.5], z in [0, 1.2]:
    # blocks a horizontal base swing but leaves an arm-upright corridor (r < 0.5) open. 0.5 not
    # 0.35: the CRX's shoulder housing sits ~0.3 m off the base axis and sweeps that circle.
    az = arm_az + math.radians(45)
    r, z = np.meshgrid(np.arange(0.5, 1.5, 0.02), np.arange(0.0, 1.2, 0.02))
    return np.stack([r.ravel() * math.cos(az), r.ravel() * math.sin(az), z.ravel()], axis=1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--robot", required=True)
    ap.add_argument("--ar-bridge", default="http://localhost:8765")
    ap.add_argument(
        "--settle",
        type=float,
        default=10.0,
        help="seconds to wait after MoveIt's services appear before uploading (see docstring)",
    )
    args = ap.parse_args()
    spec = ROBOTS[args.robot]

    rclpy.init()
    node = Check(spec)
    node.wait(lambda: node.joints is not None and node.urdf is not None, 15, "/joint_states + URDF")
    for c in (node.validity, node.planner, node.clear):
        if not c.wait_for_service(timeout_sec=30):
            raise TimeoutError(f"{c.srv_name} (is moveit.launch.py running?)")
    # A cloud that arrives in the first seconds after move_group starts is NOT self-filtered,
    # silently (found in M5a): the robot's own points land in the octomap and the start pose
    # reads as in collision. Wait it out here; the M5c adapter needs a real fix.
    time.sleep(args.settle)

    start = {
        n: p
        for n, p in zip(node.joints.name, node.joints.position, strict=True)
        if n in spec.joint_names
    }
    pan = spec.joint_names[0]
    # Wall at +45° of base rotation; goal at +120° so arms with a sideways offset from the base
    # axis (the CRX) clear the wall at the goal — a +90° goal clipped it.
    goal = dict(start, **{pan: start[pan] + math.radians(120)})
    halfway = dict(start, **{pan: start[pan] + math.pi / 4})

    # TF only arrives while the node spins, so wait (spinning) for every link with collision
    # geometry rather than sleeping.
    collision_links = [
        lk.get("name")
        for lk in ET.fromstring(node.urdf).findall("link")
        if lk.find("collision") is not None
    ]
    node.wait(
        lambda: all(
            node.tf.can_transform("base_link", lk, rclpy.time.Time()) for lk in collision_links
        ),
        15,
        "TF for every collision link",
    )
    robot = robot_surface_points(node)
    reach = robot[np.hypot(robot[:, 0], robot[:, 1]) > 0.3]  # the arm, not the base column
    if len(reach) == 0:
        raise SystemExit(
            "arm is upright: start the bringup with positions:= so it reaches out"
        )
    arm_az = math.atan2(reach[:, 1].mean(), reach[:, 0].mean())
    print(f"sampled {len(robot)} points on the robot's collision surfaces")

    # The octomap accumulates across clouds: start from empty so earlier runs can't leak in.
    node.call(node.clear, Empty.Request())
    results = {}
    results["halfway valid before upload"] = node.valid(halfway)

    pts = np.concatenate([wall(arm_az), robot]).astype(np.float32)
    req = urllib.request.Request(
        f"{args.ar_bridge}/v0/cloud?frame_id=base_link&name=moveit_check",
        data=ply.encode(pts),
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        print("uploaded:", resp.read().decode())
    time.sleep(3.0)  # updater runs at max_update_rate 1 Hz

    results["halfway IN COLLISION after upload"] = not node.valid(halfway)
    results["start still valid (self-filter)"] = node.valid(start)
    results["goal clear of the wall (test geometry sane)"] = node.valid(goal)

    plan_req = MotionPlanRequest()
    plan_req.group_name = spec.planning_group
    plan_req.start_state = node.state(start)
    plan_req.num_planning_attempts = 4
    plan_req.allowed_planning_time = 10.0
    plan_req.goal_constraints = [
        Constraints(
            joint_constraints=[
                JointConstraint(
                    joint_name=n, position=p, tolerance_above=0.01, tolerance_below=0.01, weight=1.0
                )
                for n, p in goal.items()
            ]
        )
    ]
    srv = GetMotionPlan.Request()
    srv.motion_plan_request = plan_req
    res = node.call(node.planner, srv, timeout=60).motion_plan_response
    traj = res.trajectory.joint_trajectory
    results["plan found"] = res.error_code.val == 1 and len(traj.points) > 1
    if results["plan found"]:
        waypoints = [dict(zip(traj.joint_names, p.positions, strict=True)) for p in traj.points]
        results["every waypoint collision-free"] = all(node.valid(w) for w in waypoints)
        print(f"plan: {len(waypoints)} waypoints, planning time {res.planning_time:.2f}s")

    for k, v in results.items():
        print(f"  [{'PASS' if v else 'FAIL'}] {k}")
    rclpy.shutdown()
    # the "before upload" probe is informational: it's only false if something else is in the scene
    return 0 if all(v for k, v in results.items() if k != "halfway valid before upload") else 1


if __name__ == "__main__":
    sys.exit(main())
