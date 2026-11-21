"""ar_bridge ROS 2 node: runs the aiohttp server beside an rclpy executor.

Parameters:
  http_port (int)        default 8765
  frame_id (string)      frame the published cloud is expressed in, default base_link
  output_dir (string)    where .pcd/.ply files are written, default ~/.mrros/clouds
  mesh_cache_dir (string) where converted .obj meshes are cached, default ~/.mrros/mesh_cache
  scenes_dir (string)    saved-scene library (M5c), default ~/.mrros/scenes
  late_join_delay_s (float) wait after a new volatile subscriber (e.g. a restarted move_group)
                         before re-publishing the last scan to it, default 3.0; < 0 disables
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
from std_srvs.srv import Empty

from ar_bridge.cloud import build_point_cloud2, ingest
from ar_bridge.http_api import Handlers, MeshResult, make_app
from ar_bridge.late_join import LateJoinWatcher
from ar_bridge.mesh_resolver import MeshCache, resolve_mesh
from ar_bridge.ply import DecodedCloud, PLYError, decode, merge
from ar_bridge.scenes import SceneLibrary, filter_for_upload

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
        # MoveIt's octomap only ever adds what it's sent; clear it before each publish so an
        # upload REPLACES the scene there too. "" or "none" disables. No-op without MoveIt.
        self.declare_parameter("clear_octomap_service", "/clear_octomap")
        self.declare_parameter("late_join_delay_s", 3.0)
        self.declare_parameter("scenes_dir", os.path.expanduser("~/.mrros/scenes"))

        self.port = int(self.get_parameter("http_port").value)
        self.frame_id = str(self.get_parameter("frame_id").value)
        self.output_dir = Path(self._path_param("output_dir"))
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.mesh_cache = MeshCache(self._path_param("mesh_cache_dir"))
        self.cloud_topic = str(self.get_parameter("cloud_topic").value)
        self.cloud_pub = self.create_publisher(PointCloud2, self.cloud_topic, _LATCHED_QOS)
        clear_srv = str(self.get_parameter("clear_octomap_service").value)
        # "" or "none" disables ("none" because `ros2 launch` rejects an empty `name:=`).
        enabled = clear_srv.strip().lower() not in ("", "none")
        self._clear_octomap = self.create_client(Empty, clear_srv) if enabled else None
        # One accumulator per `name` (mode=append target); see docs/protocols/ar_bridge_http.md.
        self._clouds: dict[str, DecodedCloud] = {}
        # The last non-empty cloud published, for subscribers that join late. Set from the HTTP
        # thread, read on the rclpy thread: a single reference swap, so no lock needed.
        self._last_cloud: PointCloud2 | None = None
        delay = float(self.get_parameter("late_join_delay_s").value)
        self._late_join = LateJoinWatcher(delay) if delay >= 0 else None
        if self._late_join is not None:
            self.create_timer(1.0, self._check_late_joiners)

        # M3's on_cloud and M2b's get_mesh are both live.
        self.scenes = SceneLibrary(Path(self._path_param("scenes_dir")))
        self.handlers = Handlers(
            get_mesh=self._get_mesh,
            on_cloud=self._on_cloud,
            on_clear=self._on_clear,
            scenes=self.scenes,
            on_publish_scene=self._on_publish_scene,
        )
        distro = os.environ.get("ROS_DISTRO", "?")
        self.get_logger().info(
            f"http on :{self.port}, frame_id={self.frame_id}, out={self.output_dir}, "
            f"mesh_cache={self.mesh_cache.cache_dir}, scenes={self.scenes.root}, "
            f"cloud_topic={self.cloud_topic}, "
            f"ROS_DISTRO={distro}"
        )

    def _path_param(self, name: str) -> str:
        """A path parameter with "~" expanded (the yaml and launch overrides may use it)."""
        return os.path.expanduser(str(self.get_parameter(name).value))

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
        return await self._publish(decoded, frame_id=frame_id, name=name, label=mode)

    async def _on_publish_scene(self, scene_id: str) -> dict:
        """POST /v0/scenes/{id}/publish: a stored scene, filtered with its own boxes and scan-time
        robot exactly like the app's upload-from-list, published as the live scan."""
        loop = asyncio.get_running_loop()
        manifest, kept = await loop.run_in_executor(None, self._load_filtered, scene_id)
        self._clouds["live_scan"] = kept
        result = await self._publish(kept, frame_id="base_link", name="live_scan", label=scene_id)
        return dict(result, scene=scene_id, name=manifest.get("name"))

    def _load_filtered(self, scene_id: str) -> tuple[dict, DecodedCloud]:
        manifest, cloud = self.scenes.load(scene_id)
        return manifest, filter_for_upload(manifest, cloud)

    async def _publish(
        self, decoded: DecodedCloud, *, frame_id: str, name: str, label: str
    ) -> dict:
        loop = asyncio.get_running_loop()
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
        cleared = await self._clear_moveit_octomap()
        self.cloud_pub.publish(result.message)
        self._last_cloud = result.message
        self.get_logger().info(
            f"cloud '{name}' ({label}): {result.point_count} pts -> {self.cloud_topic}, "
            f"{result.pcd_path}{' (MoveIt octomap cleared first)' if cleared else ''}"
        )
        return {
            "points": result.point_count,
            "file": str(result.pcd_path),
            "topic": self.cloud_topic,
        }

    async def _on_clear(self, meta: dict[str, str]) -> dict:
        """DELETE /v0/cloud: the app's Clear. Drops the stored scan(s), publishes an EMPTY latched
        cloud so every subscriber (RViz, MoveIt, late joiners) sees the scene emptied rather
        than keeping the last upload, and clears MoveIt's octomap. `?name=` clears one
        accumulator; without it, all. The .pcd files on disk are kept as a record."""
        name = meta.get("name")
        if name:
            self._clouds.pop(name, None)
        else:
            self._clouds.clear()
        frame_id = meta.get("frame_id") or self.frame_id
        empty = build_point_cloud2(DecodedCloud.empty(), frame_id=frame_id, stamp=Time())
        cleared = await self._clear_moveit_octomap()
        self.cloud_pub.publish(empty)
        self._last_cloud = None  # a late joiner starts empty anyway; nothing to re-send
        self.get_logger().info(
            f"cleared {name or 'all clouds'} -> empty {self.cloud_topic}"
            f"{' (MoveIt octomap cleared)' if cleared else ''}"
        )
        return {
            "cleared": name or "all",
            "topic": self.cloud_topic,
            "moveit_octomap_cleared": cleared,
        }

    async def _clear_moveit_octomap(self, timeout_s: float = 2.0) -> bool:
        """Clears MoveIt's octomap if move_group is up. Every published cloud is the complete
        scan (replace) or the complete merged accumulator (append), so clearing first is right in
        both modes. rclpy spins on its own thread; poll its future from asyncio with a timeout so
        a stuck move_group can't hold up the upload."""
        if self._clear_octomap is None or not self._clear_octomap.service_is_ready():
            return False
        future = self._clear_octomap.call_async(Empty.Request())
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout_s
        while not future.done():
            if loop.time() > deadline:
                self.get_logger().warning("clear_octomap timed out; publishing anyway")
                return False
            await asyncio.sleep(0.02)
        return True

    def _check_late_joiners(self) -> None:
        """rclpy timer (1 Hz). Latched subscribers (RViz) already got the last cloud; volatile
        ones (MoveIt's octomap updater) didn't, so re-publish to them once they've settled.
        Clearing the octomap first keeps an already-running MoveIt from double-inserting it."""
        assert self._late_join is not None
        now = self.get_clock().now().nanoseconds / 1e9
        volatile = [
            tuple(info.endpoint_gid)
            for info in self.get_subscriptions_info_by_topic(self.cloud_topic)
            if info.qos_profile.durability != QoSDurabilityPolicy.TRANSIENT_LOCAL
        ]
        if self._late_join.observe(now, volatile):
            self.get_logger().info(
                f"new volatile subscriber on {self.cloud_topic}; re-publishing the last scan in "
                f"{self._late_join.delay_s:.0f} s"
            )
        if not self._late_join.due(now) or self._last_cloud is None:
            return
        cloud = self._last_cloud

        def publish(_future: object = None) -> None:
            self.cloud_pub.publish(cloud)
            self.get_logger().info(
                f"re-published last scan ({cloud.width} pts) for a late subscriber"
            )

        # Asynchronous: blocking here would stall the executor that has to deliver the reply.
        if self._clear_octomap is not None and self._clear_octomap.service_is_ready():
            self._clear_octomap.call_async(Empty.Request()).add_done_callback(publish)
        else:
            publish()

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
