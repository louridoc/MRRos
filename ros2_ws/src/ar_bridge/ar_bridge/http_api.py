"""HTTP surface of ar_bridge. Protocol: docs/protocols/ar_bridge_http.md (v0).

Kept free of rclpy so it can be unit-tested with aiohttp's test client on any distro.
The node injects the ROS-side effects via `Handlers`.
"""

import os
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from aiohttp import web

PROTOCOL_VERSION = 0

# (bytes, content_type, sha256)
MeshResult = tuple[bytes, str, str] | None


@dataclass
class Handlers:
    """ROS-side effects injected by the node. All optional in M0."""

    on_cloud: Callable[[bytes, dict[str, str]], Awaitable[dict]] | None = None
    get_mesh: Callable[[str], Awaitable[MeshResult]] | None = None


def make_app(handlers: Handlers, *, node_name: str = "ar_bridge") -> web.Application:
    app = web.Application(client_max_size=256 * 1024 * 1024)

    async def health(_: web.Request) -> web.Response:
        return web.json_response(
            {
                "ok": True,
                "node": node_name,
                "protocol": PROTOCOL_VERSION,
                "ros_distro": os.environ.get("ROS_DISTRO", ""),
            }
        )

    async def cloud(request: web.Request) -> web.Response:
        if handlers.on_cloud is None:
            raise web.HTTPNotImplemented(reason="cloud ingest arrives in M3")
        body = await request.read()
        meta = dict(request.query.items())
        result = await handlers.on_cloud(body, meta)
        return web.json_response(result)

    async def mesh(request: web.Request) -> web.Response:
        if handlers.get_mesh is None:
            raise web.HTTPNotImplemented(reason="mesh serving arrives in M2b")
        uri = request.query.get("uri")
        if not uri:
            raise web.HTTPBadRequest(reason="missing ?uri=package://...")
        found = await handlers.get_mesh(uri)
        if found is None:
            raise web.HTTPNotFound(reason=f"no mesh for {uri}")
        data, content_type, sha256 = found
        return web.Response(body=data, content_type=content_type, headers={"X-Mesh-SHA256": sha256})

    app.add_routes(
        [
            web.get("/health", health),
            web.post("/v0/cloud", cloud),
            web.get("/v0/mesh", mesh),
        ]
    )
    return app
