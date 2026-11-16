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
