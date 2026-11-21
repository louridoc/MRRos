# ar_bridge HTTP protocol — v0 (draft)

Contract between the iOS app (`ARBridgeTransport`) and the `ar_bridge` node. Any wire change
bumps the version and adds a changelog entry. Default port `8765`; discovered via Bonjour
`_mrros._tcp` (M1) or typed manually. Identical on Humble, Jazzy and Lyrical.

## GET /health
→ `200 {"ok": true, "node": "ar_bridge", "protocol": 0, "ros_distro": "jazzy"}`
`ros_distro` is informational (shown in the app's diagnostics); the app must not branch on it.

## POST /v0/cloud  (M3)
Body: binary PLY (little-endian, `x y z` float32, optional `confidence` uint8, optional
`red green blue` uint8 — property order is strict, see `ply.py`/`PLYCodec.swift`). Query:

| param | required | meaning |
|---|---|---|
| `frame_id` | yes | frame the points are already expressed in: `base_link` if the robot has been placed (translation-only registration against the placement anchor — see `ARContainerView.Coordinator.uploadScan`), else `map` (raw AR session origin, unregistered). Full 6-DOF registration is M4's manual gizmo. |
| `name` | no | file stem AND the `mode=append` accumulation key; default an ISO-ish UTC timestamp (`%Y%m%dT%H%M%SZ`) |
| `mode` | no | `replace` (default, overwrites `name`'s accumulator) or `append` (concatenates onto whatever was last stored under `name`; missing `confidence`/`color` columns on either side are backfilled with 0/black rather than dropped — see `ply.merge`) |

Always publishes the single latched `/mrros/static_cloud` topic (`sensor_msgs/PointCloud2`,
`TRANSIENT_LOCAL` + `RELIABLE` QoS, header stamp **0** = "use the latest transform" since the
scan is static — a "now" stamp raced TF in MoveIt's self-filter, see docs/testing.md M5) regardless of `name`. Before each publish it calls MoveIt's `/clear_octomap` when move_group is up (param
`clear_octomap_service`, empty disables), since MoveIt's octomap otherwise accumulates every upload — `name` only selects the `.pcd` file
and the append accumulator, not which topic gets the update. The iOS app accumulates and
voxel-filters client-side across multiple captures and always uploads with a fixed
`name="live_scan"` + `mode=replace`, so one upload call fully replaces both the topic and that
one file (`ARContainerView.Coordinator.uploadScan`); `mode=append` exists for other producers
that want the server to do the accumulation instead.

→ `200 {"points": N, "file": "/path/x.pcd", "topic": "/mrros/static_cloud"}`
Errors: `400` malformed PLY (bad magic/format/header, unsupported property order, truncated
body) or missing/invalid `frame_id`/`mode`; `413` body over `client_max_size` (256 MiB, enforced
by aiohttp before the handler runs).

**Late subscribers (M5c).** The topic is latched, but MoveIt's octomap updater subscribes
VOLATILE, so a move_group that starts or restarts after an upload would never get it. ar_bridge
polls the topic's volatile subscriptions (1 Hz); when a new one appears it waits
`late_join_delay_s` (default 3 s, < 0 disables) for MoveIt's TF and robot state, clears the octomap
and re-publishes the last scan. Nothing to re-send after a Clear.

## DELETE /v0/cloud  (M5)
The app's **Clear**. Query: `name` (optional — clears that accumulator; without it, all),
`frame_id` (optional, for the empty message; default the node's `frame_id`).
Drops the stored scan(s), clears MoveIt's octomap (if move_group is up) and publishes an **empty**
latched cloud on the same topic, so RViz, MoveIt and late joiners all see the scene emptied. The
`.pcd` files already on disk are kept.
→ `200 {"cleared": "<name>|all", "topic": "/mrros/static_cloud", "moveit_octomap_cleared": bool}`
Errors: `501` on an ar_bridge without this endpoint (the app reports "couldn't clear ROS side").

## Scene library  (M5c)
Saved scenes on the ROS machine, same folder format as the app (`docs/protocols/scene_format.md`),
stored under the `scenes_dir` param (default `~/.mrros/scenes`; set it with
`ros2 launch ar_bridge ar_bridge.launch.py scenes_dir:=…`, or in a copy of `config/ar_bridge.yaml`).

| Method + path | Does |
|---|---|
| `GET /v0/scenes` | `{"scenes": [{"id", "manifest": {...}}]}`, newest first; folders without both files are skipped. |
| `GET /v0/scenes/{id}/{file}` | `file` = `scene.json` or `points.ply`; anything else `404`. |
| `PUT /v0/scenes/{id}/{file}` | Validated before writing (`400` on a bad manifest/PLY/id). Send `points.ply` first, `scene.json` last. |
| `DELETE /v0/scenes/{id}` | Removes the folder (`404` if missing). |
| `POST /v0/scenes/{id}/publish` | Filters the scene with its own boxes and scan-time robot, publishes it as the live scan (`live_scan`, base_link) exactly like an upload: octomap cleared first, latched, re-sent to late joiners. → upload result + `scene`, `name`. |

Ids must match `[A-Za-z0-9][A-Za-z0-9_.-]{0,127}` (no `..`), else `400`.

## GET /v0/mesh?uri=package://pkg/path.dae  (M2b)
→ `200` body = **Wavefront OBJ** bytes (`Content-Type: model/obj`), header `X-Mesh-SHA256` =
sha256 of the *source* file (same convention as the bundled-mesh manifest's `sha256` field, so
the client's tiers agree on what "the same mesh" means). Always OBJ, regardless of source
format (`.dae`/`.stl`/`.ply` in, converted server-side with `trimesh`; `.obj` in, passed
through verbatim) — **why OBJ and not USDZ**: RealityKit's `Entity(contentsOf:)` refuses
`.dae`/`.stl` outright on both iOS and macOS, but loads `.obj` directly with no up-axis
reinterpretation, unlike COLLADA through SceneKit (see the 90°-about-X fix and its investigation
notes in `tools/meshes/usdz_convert.swift`). Converting here, in Python with `trimesh`, sidesteps
that whole class of bug for network-fetched meshes and keeps this node portable to a
Linux lab PC with no Apple frameworks installed. Conversions are cached on disk by source
sha256 (`mesh_cache_dir` param, default `~/.mrros/mesh_cache`).
Errors: `400` malformed `uri` (wrong scheme, empty package/path, `..` traversal), `404`
package or file not found, `415` source format not supported for conversion, `501` not wired.

Client caching contract (`MeshProvider` tiers, see `ios/Packages/MeshProvider`): cache the
response body as `<package>/<relative-path-without-extension>.obj` under the tier-2 cache root;
`DirectoryMeshSource` tries `.usdz` (tier 1/2 bundled convention) then `.obj` (tier 3 convention)
when no manifest entry names the file explicitly.

## Changelog
- v0 (2026-11-15): initial draft; only `/health` live in M0.
- v0 (2026-11-17): `/v0/mesh` implemented — always serves OBJ (converted from DAE/STL/PLY with
  `trimesh` if needed), not a format negotiated by `Accept`; `X-Mesh-SHA256` is the *source*
  file's hash. Error set narrowed to what the resolver actually raises (`400`/`404`/`415`).
- v0 (2026-11-17): `/v0/cloud` implemented (`ply.py`, `cloud.py`, `node.py`'s `_on_cloud`) —
  `501` dropped from its error set now that it's wired; `mode=append`'s accumulation key and
  backfill semantics specified above once actually built, instead of left open in the draft.
- v0 (2026-11-18): `DELETE /v0/cloud` added; uploads clear MoveIt's octomap first; cloud stamp 0.
- v0 (2026-11-21): last scan re-published to late VOLATILE subscribers (move_group (re)start).
- v0 (2026-11-21): scene library endpoints (`/v0/scenes...`).
