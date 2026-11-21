"""M5 check: does a scan uploaded through ar_bridge end up as an obstacle MoveIt plans around?

Needs dev.launch.py + moveit.launch.py running for the same robot (UR or CRX). Uploads, via
ar_bridge's real HTTP endpoint (same path the app uses), a wall of points across the arm's
base-joint sweep plus points sampled on the SURFACE of the robot's own collision meshes at its
current pose — what a real LiDAR scan of the robot looks like — then checks:

  1. the sweep's halfway configuration goes from valid → in collision   (cloud reached MoveIt)
  2. the start configuration stays valid                                 (robot filtered out)
  3. MoveIt finds a plan to the goal and every waypoint is collision-free
  4. with --execute: MoveIt executes it (mock_joints' fake controller) and /joint_states ends at
     the goal — bringup with moveit:=true frozen:=true (a sweeping robot fails the start check)

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
from moveit_msgs.action import ExecuteTrajectory
from moveit_msgs.msg import Constraints, JointConstraint, MotionPlanRequest, RobotState
from moveit_msgs.srv import GetMotionPlan, GetStateValidity
from rclpy.action import ActionClient
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import JointState
from std_msgs.msg import String
from std_srvs.srv import Empty
from tf2_ros import Buffer, TransformListener

sys.path.insert(0, "ros2_ws/src/ar_bridge")
sys.path.insert(0, "ros2_ws/src/ar_dev_bringup")
from ar_bridge import mesh_ply, ply  # noqa: E402
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


def wall(arm_az: float, side: float) -> np.ndarray:
    # Vertical half-plane through the base axis at arm_az ± 45°, r in [0.7, 1.5], z in [0, 1.2]:
    # blocks a horizontal base swing but leaves an arm-upright corridor (r < 0.7) open. The CRX's
    # shoulder housing sits ~50° to one side of the arm's direction, out to ~0.5 m: it trails the
    # arm swinging one way but leads (and would start inside a 0.5 m corridor) swinging the other.
    az = arm_az + side * math.radians(45)
    r, z = np.meshgrid(np.arange(0.7, 1.5, 0.02), np.arange(0.0, 1.2, 0.02))
    return np.stack([r.ravel() * math.cos(az), r.ravel() * math.sin(az), z.ravel()], axis=1)


def wall_mesh(arm_az: float, side: float) -> tuple[np.ndarray, np.ndarray]:
    """The same wall as `wall`, as a 4 cm thick box of 12 triangles (the --mesh path)."""
    az = arm_az + side * math.radians(45)
    along = np.array([math.cos(az), math.sin(az), 0.0])
    normal = np.array([-math.sin(az), math.cos(az), 0.0])
    corners = [
        r * along + t * normal + np.array([0, 0, z])
        for r in (0.7, 1.5)
        for t in (-0.02, 0.02)
        for z in (0.0, 1.2)
    ]
    # corner index = 4*r + 2*t + z (each 0/1); two triangles per box face
    faces = [
        (0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5),  # r = 0.7, r = 1.5
        (0, 4, 5), (0, 5, 1), (2, 3, 7), (2, 7, 6),  # t = -, t = +
        (0, 2, 6), (0, 6, 4), (1, 5, 7), (1, 7, 3),  # z = 0, z = 1.2
    ]
    return np.array(corners, np.float32), np.array(faces, np.uint32)


def _request(url: str, method: str, data: bytes | None = None) -> str:
    req = urllib.request.Request(url, data=data, method=method)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--robot", required=True)
    ap.add_argument("--ar-bridge", default="http://localhost:8765")
    ap.add_argument(
        "--execute", action="store_true", help="also execute the plan (fake controller)"
    )
    ap.add_argument(
        "--settle",
        type=float,
        default=0.0,
        help="optional wait after MoveIt's services appear before uploading",
    )
    ap.add_argument(
        "--no-upload",
        action="store_true",
        help="check the scene MoveIt already has (no clear, no upload) — e.g. after restarting "
        "move_group, to test that ar_bridge re-published the last scan to it",
    )
    ap.add_argument(
        "--mesh",
        action="store_true",
        help="upload the wall as a scan MESH (MoveIt collision object via ar_bridge) instead of "
        "points; no robot geometry is sent (the phone filters it out of meshes)",
    )
    ap.add_argument(
        "--clear-after",
        action="store_true",
        help="finally DELETE /v0/cloud (the app's Clear) and check the obstacle is gone",
    )
    args = ap.parse_args()
    spec = ROBOTS[args.robot]

    rclpy.init()
    node = Check(spec)
    # 60 s: a freshly launched stack (MoveIt included) takes a while to come up
    node.wait(lambda: node.joints is not None and node.urdf is not None, 60, "/joint_states + URDF")
    for c in (node.validity, node.planner, node.clear):
        if not c.wait_for_service(timeout_sec=60):
            raise TimeoutError(f"{c.srv_name} (is moveit.launch.py running?)")
    # Not needed since ar_bridge stamps clouds 0 (see node.py); kept for experiments.
    time.sleep(args.settle)

    start = {
        n: p
        for n, p in zip(node.joints.name, node.joints.position, strict=True)
        if n in spec.joint_names
    }
    pan = spec.joint_names[0]
    # Wall at +45° of base rotation; goal at +120° so arms with a sideways offset from the base
    # axis (the CRX) clear the wall at the goal — a +90° goal clipped it.
    # Swing toward the side with room left in the joint range: after an --execute run the arm
    # is held at the previous goal, and +120° more would leave a ±180° base joint's limits.
    side = -1.0 if start[pan] > 0 else 1.0
    goal = dict(start, **{pan: start[pan] + side * math.radians(120)})
    halfway = dict(start, **{pan: start[pan] + side * math.pi / 4})

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
        raise SystemExit("arm is upright: start the bringup with positions:= so it reaches out")
    arm_az = math.atan2(reach[:, 1].mean(), reach[:, 0].mean())
    print(f"sampled {len(robot)} points on the robot's collision surfaces")

    results = {}
    if args.no_upload:
        print("--no-upload: checking the scene MoveIt already has")
    else:
        # Start from an empty scene so earlier runs can't leak in: the app's Clear empties both
        # the octomap and the scan-mesh collision object.
        print("cleared:", _request(f"{args.ar_bridge}/v0/cloud", "DELETE"))
        node.call(node.clear, Empty.Request())
        results["halfway valid before upload"] = node.valid(halfway)

        if args.mesh:
            verts, tris = wall_mesh(arm_az, side)
            body = mesh_ply.encode(verts, tris)
            url = f"{args.ar_bridge}/v0/scene_mesh?frame_id=base_link"
            print("uploaded:", _request(url, "POST", body))
            time.sleep(1.0)
        else:
            pts = np.concatenate([wall(arm_az, side), robot]).astype(np.float32)
            url = f"{args.ar_bridge}/v0/cloud?frame_id=base_link&name=moveit_check"
            print("uploaded:", _request(url, "POST", ply.encode(pts)))
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

    if args.execute and results["plan found"]:
        executor = ActionClient(node, ExecuteTrajectory, "/execute_trajectory")
        if not executor.wait_for_server(timeout_sec=10):
            raise TimeoutError("/execute_trajectory")
        sent = executor.send_goal_async(ExecuteTrajectory.Goal(trajectory=res.trajectory))
        node.wait(sent.done, 10, "execute goal accepted")
        done = sent.result().get_result_async()
        node.wait(done.done, 120, "trajectory execution")
        results["executed (MoveIt reports success)"] = done.result().result.error_code.val == 1

        def at_goal():
            now = dict(zip(node.joints.name, node.joints.position, strict=True))
            return all(abs(now[n] - p) < 0.02 for n, p in goal.items())

        try:
            node.wait(at_goal, 5, "joint_states at goal")
            results["/joint_states reached the goal"] = True
        except TimeoutError:
            results["/joint_states reached the goal"] = False

    if args.clear_after:
        print("cleared:", _request(f"{args.ar_bridge}/v0/cloud", "DELETE"))
        time.sleep(2.0)
        results["Clear removed the obstacle (halfway valid again)"] = node.valid(halfway)

    for k, v in results.items():
        print(f"  [{'PASS' if v else 'FAIL'}] {k}")
    rclpy.shutdown()
    # the "before upload" probe is informational: it's only false if something else is in the scene
    return 0 if all(v for k, v in results.items() if k != "halfway valid before upload") else 1


if __name__ == "__main__":
    sys.exit(main())
