# Saved scene format (M5c) — `mrros.scene` v1

A scene is one folder holding two files. The same folder layout is used on the phone
(`Documents/Scenes/<id>/`, visible in the Files app) and by ar_bridge (`~/.mrros/scenes/<id>/`,
param `scenes_dir`). Writers: `ios/Packages/SceneLibrary` (Swift) and `ar_bridge/scenes.py`
(validation + filtering). Both must change together; the cross-language fixture
`ros2_ws/src/ar_bridge/test/fixtures/scene_v1` (written by Swift, checked by Python) guards it.

| File | Content |
|---|---|
| `points.ply` | The raw scan, **unfiltered**, in `base_link`, ROS axes (binary PLY, same codec as `POST /v0/cloud`). |
| `mesh.ply` | *Optional* (M5c part 3): ARKit's room mesh, raw, base_link (binary PLY with triangles, the `POST /v0/scene_mesh` format). |
| `scene.json` | Manifest below. Written **after** the other files: a folder with a manifest is complete. |

`<id>` is the folder name: `[A-Za-z0-9][A-Za-z0-9_.-]{0,127}`. The app generates
`<name-slug>_<yyyyMMdd-HHmmss UTC>_<4 hex>`.

## scene.json

| Key | Type | Meaning |
|---|---|---|
| `format` | `"mrros.scene"` | |
| `version` | int | `1`. Readers refuse a higher version. |
| `name` | string | User-facing name (rename edits only this). |
| `createdAt` | ISO 8601 | |
| `frameId` | `"base_link"` | Always. Points and boxes are robot-relative, so a scene survives re-placing the robot. |
| `robotName` | string? | `robot_description` name at save time; loading warns on a mismatch. |
| `joints` | {name: rad} | Joint angles at save time (informational). |
| `pointCount` | int | |
| `triangleCount` | int? | Triangles in `mesh.ply`; absent = no mesh. Optional key, so v1 is unchanged. |
| `cropEnabled`, `crop` | bool, Box | Crop box: points outside it are dropped when enabled. |
| `exclusions` | [Box] | Points inside any are dropped. |
| `robotBoxes` | [StoredBox] | The robot's link boxes **at scan time**. Dropped (with `robotPadding`) on every later filter, so the real robot's old pose can't reappear as an obstacle after it moves. |
| `robotPadding` | float (m) | Grows the robot boxes on every side. |

- **Box** (`BaseLinkBox`): `{"center": [x,y,z], "half": [x,y,z], "yaw": rad}`. Rotated about base Z
  by `yaw`, then translated to `center`; extent `±half`.
- **StoredBox**: `{"baseLinkFromBox": [16 floats, column-major 4×4], "min": [x,y,z], "max": [x,y,z]}`.

## Filtering (what an upload sends)

Keep a point unless it is inside a robot box (padded), inside an exclusion box, or (crop enabled)
outside the crop. Mesh triangles are kept or dropped by their **centroid** with the same rule;
unused vertices are dropped and indices renumbered in first-use order (Swift and Python agree
exactly — fixture `expected_kept_mesh.ply`). Containment is inclusive. The app additionally drops points inside the *live*
robot when one is placed; ar_bridge's `publish` uses the scene alone.
