"""ar_bridge ROS 2 node: runs the aiohttp server beside an rclpy executor.

Parameters:
  http_port (int)        default 8765
  frame_id (string)      frame the published cloud is expressed in, default base_link
  output_dir (string)    where .pcd/.ply files are written, default ~/.mrros/clouds
  mesh_cache_dir (string) where converted .obj meshes are cached, default ~/.mrros/mesh_cache
  scenes_dir (string)    saved-scene library (M5c), default ~/.mrros/scenes
  collision_object_id (string) MoveIt collision object holding the scan mesh,
                         default mrros_scan_mesh
  apply_planning_scene_service (string) default /apply_planning_scene; "none" disables meshes
  planning_scene_topic (string) watched for a (re)started move_group to re-send the mesh,
                         default /planning_scene
  republish_after_s (float) send each scan once more this long after publishing, default 1.5;
                         MoveIt's updater drops clouds arriving within 1/max_update_rate (1 s)
                         of the previous one (e.g. right after a Clear). < 0 disables
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

from ar_bridge import mesh_ply
from ar_bridge.cloud import build_point_cloud2, ingest
from ar_bridge.collision import apply_request, collision_object, moveit_available
from ar_bridge.http_api import Handlers, MeshResult, make_app
from ar_bridge.late_join import LateJoinWatcher
from ar_bridge.mesh_resolver import MeshCache, resolve_mesh
from ar_bridge.ply import DecodedCloud, PLYError, decode, merge
from ar_bridge.scenes import SceneLibrary, filter_for_upload, filter_mesh_for_upload

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
        self.declare_parameter("republish_after_s", 1.5)
        self.declare_parameter("scenes_dir", os.path.expanduser("~/.mrros/scenes"))
        self.declare_parameter("collision_object_id", "mrros_scan_mesh")
        self.declare_parameter("apply_planning_scene_service", "/apply_planning_scene")
        self.declare_parameter("planning_scene_topic", "/planning_scene")

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
        self._republish_after = float(self.get_parameter("republish_after_s").value)
        # Bumped whenever the CONTENT changes (upload, scene publish, Clear): a pending re-send
        # of older content is dropped. Re-sends of the same scan never clear the octomap.
        self._publish_generation = 0
        # (due time, generation) of the follow-up to a late-joiner re-send (rclpy thread).
        self._late_followup: tuple[float, int] | None = None
        delay = float(self.get_parameter("late_join_delay_s").value)
        self._late_join = LateJoinWatcher(delay) if delay >= 0 else None

        # Scan mesh -> MoveIt collision object (M5c). Needs moveit_msgs; without it the mesh
        # endpoint answers 501 and everything else works as before.
        self.collision_object_id = str(self.get_parameter("collision_object_id").value)
        self.planning_scene_topic = str(self.get_parameter("planning_scene_topic").value)
        apply_srv = str(self.get_parameter("apply_planning_scene_service").value)
        self._apply_scene = None
        if apply_srv.strip().lower() not in ("", "none") and moveit_available():
            from moveit_msgs.srv import ApplyPlanningScene

            self._apply_scene = self.create_client(ApplyPlanningScene, apply_srv)
        # The last mesh applied, re-sent to a (re)started move_group; None after a Clear.
        self._last_mesh: mesh_ply.DecodedMesh | None = None
        self._mesh_frame = self.frame_id
        self._mesh_join = LateJoinWatcher(delay) if delay >= 0 else None
        self._mesh_resend_pending = False

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
            on_scene_mesh=self._on_scene_mesh if self._apply_scene is not None else None,
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
        manifest, kept, mesh = await loop.run_in_executor(None, self._load_filtered, scene_id)
        self._clouds["live_scan"] = kept
        result = await self._publish(kept, frame_id="base_link", name="live_scan", label=scene_id)
        out = dict(result, scene=scene_id, name=manifest.get("name"))
        if mesh is not None and len(mesh.triangles) and self._apply_scene is not None:
            obj = await loop.run_in_executor(
                None,
                lambda: collision_object(
                    mesh, frame_id="base_link", object_id=self.collision_object_id
                ),
            )
            self._last_mesh, self._mesh_frame = mesh, "base_link"
            out["triangles"] = int(len(mesh.triangles))
            out["mesh_applied"] = await self._apply(obj, timeout_s=30.0)
        return out

    def _load_filtered(self, scene_id: str):
        manifest, cloud, mesh = self.scenes.load(scene_id)
        kept_mesh = filter_mesh_for_upload(manifest, mesh) if mesh is not None else None
        return manifest, filter_for_upload(manifest, cloud), kept_mesh

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
        self._publish_generation += 1
        if self._republish_after >= 0:
            asyncio.get_running_loop().create_task(
                self._republish_later(self._publish_generation, result.message)
            )
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
        self._publish_generation += 1  # cancels a pending re-send of the cleared scan
        mesh_removed = False
        if self._last_mesh is not None and self._apply_scene is not None:
            self._last_mesh = None
            remove = collision_object(
                None, frame_id=self._mesh_frame, object_id=self.collision_object_id
            )
            mesh_removed = await self._apply(remove, timeout_s=5.0)
        self.get_logger().info(
            f"cleared {name or 'all clouds'} -> empty {self.cloud_topic}"
            f"{' (MoveIt octomap cleared)' if cleared else ''}"
        )
        return {
            "cleared": name or "all",
            "topic": self.cloud_topic,
            "moveit_octomap_cleared": cleared,
            "moveit_mesh_removed": mesh_removed,
        }

    async def _republish_later(self, generation: int, message: PointCloud2) -> None:
        """Measured (M5c): Clear then upload within a second, and MoveIt's updater (1 Hz) dropped
        the scan; the octomap stayed empty. One more send after the throttle window makes the
        latest scan land; skipped if anything newer was published or cleared meanwhile."""
        await asyncio.sleep(self._republish_after)
        if generation == self._publish_generation:
            self.cloud_pub.publish(message)

    async def _on_scene_mesh(self, body: bytes, meta: dict[str, str]) -> dict:
        """POST /v0/scene_mesh: the app's filtered scan mesh -> one MoveIt collision object
        (replaced on every upload, removed by Clear, re-sent if move_group restarts). Unlike the
        cloud, MoveIt does NOT self-filter collision objects: the phone must have removed the
        robot's triangles, or the start state is in collision."""
        frame_id = meta.get("frame_id")
        if not frame_id:
            raise PLYError(400, "missing ?frame_id=...")
        loop = asyncio.get_running_loop()
        mesh = await loop.run_in_executor(None, mesh_ply.decode, body)
        obj = await loop.run_in_executor(
            None,
            lambda: collision_object(mesh, frame_id=frame_id, object_id=self.collision_object_id),
        )
        self._last_mesh, self._mesh_frame = mesh, frame_id
        applied = await self._apply(obj, timeout_s=30.0)
        self.get_logger().info(
            f"scan mesh: {len(mesh.triangles)} triangles -> collision object "
            f"'{self.collision_object_id}' "
            f"({'applied' if applied else 'MoveIt not up; kept for later'})"
        )
        return {
            "triangles": int(len(mesh.triangles)),
            "vertices": int(len(mesh.vertices)),
            "object_id": self.collision_object_id,
            "applied": applied,
        }

    async def _apply(self, obj, *, timeout_s: float) -> bool:
        """ApplyPlanningScene from the asyncio thread; False if MoveIt isn't up or fails."""
        if self._apply_scene is None or not self._apply_scene.service_is_ready():
            return False
        future = self._apply_scene.call_async(apply_request(obj))
        if not await self._wait(future, timeout_s):
            self.get_logger().warning("apply_planning_scene timed out")
            return False
        return bool(future.result().success)

    @staticmethod
    async def _wait(future, timeout_s: float) -> bool:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout_s
        while not future.done():
            if loop.time() > deadline:
                return False
            await asyncio.sleep(0.02)
        return True

    async def _clear_moveit_octomap(self, timeout_s: float = 2.0) -> bool:
        """Clears MoveIt's octomap if move_group is up. Every published cloud is the complete
        scan (replace) or the complete merged accumulator (append), so clearing first is right in
        both modes. rclpy spins on its own thread; poll its future from asyncio with a timeout so
        a stuck move_group can't hold up the upload."""
        if self._clear_octomap is None or not self._clear_octomap.service_is_ready():
            return False
        future = self._clear_octomap.call_async(Empty.Request())
        if not await self._wait(future, timeout_s):
            self.get_logger().warning("clear_octomap timed out; publishing anyway")
            return False
        return True

    def _check_late_joiners(self) -> None:
        """rclpy timer (1 Hz). Latched subscribers (RViz) already got the last cloud; volatile
        ones (MoveIt's octomap updater) didn't, so re-publish to them once they've settled.
        Clearing the octomap first keeps an already-running MoveIt from double-inserting it."""
        assert self._late_join is not None
        now = self.get_clock().now().nanoseconds / 1e9
        self._check_mesh_joiners(now)
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
        if self._late_followup is not None and now >= self._late_followup[0]:
            generation = self._late_followup[1]
            self._late_followup = None
            if generation == self._publish_generation and self._last_cloud is not None:
                self.cloud_pub.publish(self._last_cloud)
        if not self._late_join.due(now) or self._last_cloud is None:
            return
        # Same scan again: no octomap clear (that would wipe a copy MoveIt already has and the
        # re-send may then be throttled away — measured). Its own follow-up covers the throttle.
        self.cloud_pub.publish(self._last_cloud)
        if self._republish_after >= 0:
            self._late_followup = (now + self._republish_after, self._publish_generation)
        self.get_logger().info(
            f"re-published last scan ({self._last_cloud.width} pts) for a late subscriber"
        )

    def _check_mesh_joiners(self, now: float) -> None:
        """A (re)started move_group has an empty world: re-apply the last scan mesh once its
        planning-scene subscription appears and the service answers."""
        if self._mesh_join is None or self._apply_scene is None:
            return
        ids = [
            tuple(i.endpoint_gid)
            for i in self.get_subscriptions_info_by_topic(self.planning_scene_topic)
        ]
        self._mesh_join.observe(now, ids)
        if self._mesh_join.due(now) and self._last_mesh is not None:
            self._mesh_resend_pending = True
        if not self._mesh_resend_pending or not self._apply_scene.service_is_ready():
            return
        self._mesh_resend_pending = False
        mesh, frame = self._last_mesh, self._mesh_frame
        if mesh is None:
            return
        obj = collision_object(mesh, frame_id=frame, object_id=self.collision_object_id)
        self._apply_scene.call_async(apply_request(obj)).add_done_callback(
            lambda f: self.get_logger().info(
                f"re-applied scan mesh ({len(mesh.triangles)} triangles) for a (re)started "
                f"move_group: {'ok' if f.result() and f.result().success else 'FAILED'}"
            )
        )

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
