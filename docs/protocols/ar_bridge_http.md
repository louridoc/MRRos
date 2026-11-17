# ar_bridge HTTP protocol — v0 (draft)

Contract between the iOS app (`ARBridgeTransport`) and the `ar_bridge` node. Any wire change
bumps the version and adds a changelog entry. Default port `8765`; discovered via Bonjour
`_mrros._tcp` (M1) or typed manually. Identical on Humble, Jazzy and Lyrical.

## GET /health
→ `200 {"ok": true, "node": "ar_bridge", "protocol": 0, "ros_distro": "jazzy"}`
`ros_distro` is informational (shown in the app's diagnostics); the app must not branch on it.

## POST /v0/cloud  (M3)
Body: binary PLY (little-endian, `x y z` float32, optional `confidence` uint8, optional
`red green blue` uint8). Query:

| param | required | meaning |
|---|---|---|
| `frame_id` | yes | frame the points are already expressed in (`base_link` after alignment) |
| `name` | no | file stem; default ISO timestamp |
| `mode` | no | `replace` (default) or `append` to the latched cloud |

→ `200 {"points": N, "file": "/path/x.pcd", "topic": "/mrros/static_cloud"}`
Errors: `400` malformed PLY, `413` too large (>256 MiB), `501` not wired.

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
