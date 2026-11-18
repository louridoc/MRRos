"""ar_bridge ROS 2 node: runs the aiohttp server beside an rclpy executor.

Parameters:
  http_port (int)        default 8765
  frame_id (string)      frame the published cloud is expressed in, default base_link
  output_dir (string)    where .pcd/.ply files are written, default ~/.mrros/clouds
  mesh_cache_dir (string) where converted .obj meshes are cached, default ~/.mrros/mesh_cache
"""

import asyncio
import os
import threading
import time
from pathlib import Path

import rclpy
from aiohttp import web
from builtin_interfaces.msg import Time
from rclpy.node import Node
from rclpy.qos import QoSDurabilityPolicy, QoSProfile, QoSReliabilityPolicy
from sensor_msgs.msg import PointCloud2

from ar_bridge.cloud import ingest
from ar_bridge.http_api import Handlers, MeshResult, make_app
from ar_bridge.mesh_resolver import MeshCache, resolve_mesh
from ar_bridge.ply import DecodedCloud, PLYError, decode, merge

_LATCHED_QOS = QoSProfile(
    depth=1,
    reliability=QoSReliabilityPolicy.RELIABLE,
    durability=QoSDurabilityPolicy.TRANSIENT_LOCAL,
)


class ARBridge(Node):
    def __init__(self) -> None:
        super().__init__("ar_bridge")
        self.declare_parameter("http_port", 8765)
        self.declare_parameter("frame_id", "base_link")
        self.declare_parameter("output_dir", os.path.expanduser("~/.mrros/clouds"))
        self.declare_parameter("mesh_cache_dir", os.path.expanduser("~/.mrros/mesh_cache"))
        self.declare_parameter("cloud_topic", "/mrros/static_cloud")

        self.port = int(self.get_parameter("http_port").value)
        self.frame_id = str(self.get_parameter("frame_id").value)
        self.output_dir = Path(str(self.get_parameter("output_dir").value))
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.mesh_cache = MeshCache(str(self.get_parameter("mesh_cache_dir").value))
        self.cloud_topic = str(self.get_parameter("cloud_topic").value)
        self.cloud_pub = self.create_publisher(PointCloud2, self.cloud_topic, _LATCHED_QOS)
        # One accumulator per `name` (mode=append target); see docs/protocols/ar_bridge_http.md.
        self._clouds: dict[str, DecodedCloud] = {}

        # M3's on_cloud and M2b's get_mesh are both live.
        self.handlers = Handlers(get_mesh=self._get_mesh, on_cloud=self._on_cloud)
        distro = os.environ.get("ROS_DISTRO", "?")
        self.get_logger().info(
            f"http on :{self.port}, frame_id={self.frame_id}, out={self.output_dir}, "
            f"mesh_cache={self.mesh_cache.cache_dir}, cloud_topic={self.cloud_topic}, "
            f"ROS_DISTRO={distro}"
        )

    async def _get_mesh(self, uri: str) -> MeshResult:
        # trimesh conversion is blocking CPU work; keep it off the event loop so one slow
        # conversion doesn't stall every other request (including concurrent /health checks).
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, resolve_mesh, uri, self.mesh_cache)

    async def _on_cloud(self, body: bytes, meta: dict[str, str]) -> dict:
        frame_id = meta.get("frame_id")
        if not frame_id:
            raise PLYError(400, "missing ?frame_id=...")
        mode = meta.get("mode", "replace")
        if mode not in ("replace", "append"):
            raise PLYError(400, f"mode must be 'replace' or 'append', got {mode!r}")
        name = meta.get("name") or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())

        loop = asyncio.get_running_loop()
        decoded = await loop.run_in_executor(None, decode, body)  # PLY parsing is pure CPU work

        if mode == "append" and name in self._clouds:
            decoded = merge(self._clouds[name], decoded)
        self._clouds[name] = decoded

        # PCD writing is the dominant cost at scan scale (~2s/1M points even vectorized) — keep
        # it off the event loop too, same reasoning as decode() above.
        #
        # Stamp 0 = "use the latest transform": this is static data (the robot doesn't move during
        # a scan). Stamping it "now" raced TF — MoveIt's self-filter looks up every robot link at
        # the cloud's exact stamp, which is often a few ms newer than the last 30 Hz joint TF, so
        # some links weren't filtered and the robot collided with its own scan, intermittently.
        stamp = Time()
        result = await loop.run_in_executor(
            None,
            lambda: ingest(
                decoded,
                frame_id=frame_id,
                output_dir=self.output_dir,
                name=name,
                clock_now=stamp,
            ),
        )
        self.cloud_pub.publish(result.message)
        self.get_logger().info(
            f"cloud '{name}' ({mode}): {result.point_count} pts -> {self.cloud_topic}, "
            f"{result.pcd_path}"
        )
        return {
            "points": result.point_count,
            "file": str(result.pcd_path),
            "topic": self.cloud_topic,
        }

    def serve_forever(self) -> None:
        app = make_app(self.handlers, node_name=self.get_name())
        web.run_app(app, host="0.0.0.0", port=self.port, print=None, handle_signals=False)


def main() -> None:
    rclpy.init()
    node = ARBridge()
    spin = threading.Thread(target=rclpy.spin, args=(node,), daemon=True)
    spin.start()
    try:
        node.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()
