import pytest
from aiohttp.test_utils import TestClient, TestServer

from ar_bridge.http_api import PROTOCOL_VERSION, Handlers, make_app


@pytest.fixture
async def client():
    app = make_app(Handlers(), node_name="test")
    async with TestClient(TestServer(app)) as c:
        yield c


async def test_health(client: TestClient, monkeypatch):
    monkeypatch.setenv("ROS_DISTRO", "humble")
    r = await client.get("/health")
    assert r.status == 200
    body = await r.json()
    assert body["ok"] is True
    assert body["protocol"] == PROTOCOL_VERSION
    assert body["ros_distro"] == "humble"


async def test_unwired_endpoints_are_501(client: TestClient):
    assert (await client.post("/v0/cloud", data=b"")).status == 501
    assert (await client.get("/v0/mesh", params={"uri": "package://x/y.dae"})).status == 501


async def test_cloud_handler_receives_bytes_and_query():
    seen = {}

    async def on_cloud(data: bytes, meta: dict[str, str]) -> dict:
        seen["data"], seen["meta"] = data, meta
        return {"points": 3}

    app = make_app(Handlers(on_cloud=on_cloud))
    async with TestClient(TestServer(app)) as c:
        r = await c.post("/v0/cloud", params={"frame_id": "map"}, data=b"PLY")
        assert r.status == 200
        assert (await r.json()) == {"points": 3}
    assert seen == {"data": b"PLY", "meta": {"frame_id": "map"}}


async def test_cloud_handler_maps_resolver_error_status():
    class Boom(Exception):
        status = 400

    async def on_cloud(data: bytes, meta: dict[str, str]) -> dict:
        raise Boom("malformed PLY")

    app = make_app(Handlers(on_cloud=on_cloud))
    async with TestClient(TestServer(app)) as c:
        r = await c.post("/v0/cloud", params={"frame_id": "map"}, data=b"not ply")
        assert r.status == 400
        assert "malformed PLY" in await r.text()


async def test_mesh_handler_returns_body_content_type_and_sha_header():
    async def get_mesh(uri: str):
        assert uri == "package://pkg/a.obj"
        return b"OBJDATA", "model/obj", "deadbeef"

    app = make_app(Handlers(get_mesh=get_mesh))
    async with TestClient(TestServer(app)) as c:
        r = await c.get("/v0/mesh", params={"uri": "package://pkg/a.obj"})
        assert r.status == 200
        assert await r.read() == b"OBJDATA"
        assert r.headers["X-Mesh-SHA256"] == "deadbeef"
        assert r.content_type == "model/obj"


async def test_mesh_handler_missing_uri_is_400():
    app = make_app(Handlers(get_mesh=lambda uri: None))
    async with TestClient(TestServer(app)) as c:
        assert (await c.get("/v0/mesh")).status == 400


async def test_mesh_handler_maps_resolver_error_status():
    class Boom(Exception):
        status = 404

    async def get_mesh(uri: str):
        raise Boom("no such package")

    app = make_app(Handlers(get_mesh=get_mesh))
    async with TestClient(TestServer(app)) as c:
        r = await c.get("/v0/mesh", params={"uri": "package://ghost/x.dae"})
        assert r.status == 404
        assert "no such package" in await r.text()


async def test_mesh_handler_unstatused_exception_is_500():
    async def get_mesh(uri: str):
        raise RuntimeError("bug")

    app = make_app(Handlers(get_mesh=get_mesh))
    async with TestClient(TestServer(app)) as c:
        r = await c.get("/v0/mesh", params={"uri": "package://pkg/a.obj"})
        assert r.status == 500


async def test_clear_cloud_handler_receives_query_and_returns_result():
    seen = {}

    async def on_clear(meta: dict[str, str]) -> dict:
        seen["meta"] = meta
        return {"cleared": "live_scan", "moveit_octomap_cleared": True}

    app = make_app(Handlers(on_clear=on_clear))
    async with TestClient(TestServer(app)) as c:
        r = await c.delete("/v0/cloud", params={"name": "live_scan"})
        assert r.status == 200
        assert (await r.json())["cleared"] == "live_scan"
    assert seen == {"meta": {"name": "live_scan"}}


async def test_clear_cloud_unwired_is_501():
    app = make_app(Handlers())
    async with TestClient(TestServer(app)) as c:
        assert (await c.delete("/v0/cloud")).status == 501
