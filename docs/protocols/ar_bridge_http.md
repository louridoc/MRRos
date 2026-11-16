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
→ `200` body = mesh bytes converted to a format iOS can load (`model/obj` or `model/stl`),
header `X-Mesh-SHA256`. Content negotiated by `Accept` later if needed.
Errors: `400` missing uri, `404` package/file not found, `501` not wired.

## Changelog
- v0 (2026-11-15): initial draft; only `/health` live in M0.
