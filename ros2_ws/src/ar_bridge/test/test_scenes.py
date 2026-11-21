import json
import shutil
from pathlib import Path

import numpy as np
import pytest
from aiohttp.test_utils import TestClient, TestServer

from ar_bridge.http_api import Handlers, make_app
from ar_bridge.ply import decode, encode
from ar_bridge.scenes import SceneError, SceneLibrary, filter_for_upload, parse_manifest

FIXTURE = Path(__file__).parent / "fixtures" / "scene_v1"


def _manifest(**overrides) -> dict:
    m = {
        "format": "mrros.scene",
        "version": 1,
        "frameId": "base_link",
        "name": "bench",
        "createdAt": "2026-11-21T10:00:00Z",
        "cropEnabled": False,
        "crop": {"center": [0, 0, 0.5], "half": [1, 1, 0.5], "yaw": 0},
        "exclusions": [],
        "robotBoxes": [],
        "robotPadding": 0.0,
        "joints": {},
        "pointCount": 2,
    }
    m.update(overrides)
    return m


def _points() -> bytes:
    return encode(np.array([[0.1, 0, 0.5], [2.0, 0, 0.5]], dtype=np.float32))


def test_filter_matches_swift_exactly() -> None:
    """The fixture was written by SceneLibrary's Swift filter (see CrossLanguageFixture there):
    rotated robot box (column-major matrix), padding, yawed exclusion and crop."""
    manifest = parse_manifest((FIXTURE / "scene.json").read_bytes())
    cloud = decode((FIXTURE / "points.ply").read_bytes())
    expected = decode((FIXTURE / "expected_kept.ply").read_bytes())
    kept = filter_for_upload(manifest, cloud)
    assert kept.count == expected.count
    np.testing.assert_array_equal(kept.xyz, expected.xyz)


def test_library_round_trip_list_and_delete(tmp_path: Path) -> None:
    lib = SceneLibrary(tmp_path)
    lib.write("bench_1", "points.ply", _points())
    assert lib.list() == []  # no manifest yet = incomplete, not listed
    lib.write("bench_1", "scene.json", json.dumps(_manifest()).encode())
    lib.write("old_1", "points.ply", _points())
    old = _manifest(createdAt="2025-01-01T00:00:00Z")
    lib.write("old_1", "scene.json", json.dumps(old).encode())
    assert [r["id"] for r in lib.list()] == ["bench_1", "old_1"]
    manifest, cloud = lib.load("bench_1")
    assert manifest["name"] == "bench" and cloud.count == 2
    lib.delete("bench_1")
    assert [r["id"] for r in lib.list()] == ["old_1"]


def test_swift_written_fixture_is_listed(tmp_path: Path) -> None:
    shutil.copytree(FIXTURE, tmp_path / "scene_v1")
    assert [r["id"] for r in SceneLibrary(tmp_path).list()] == ["scene_v1"]


@pytest.mark.parametrize("bad", ["../etc", ".hidden", "a/b", "", "x" * 200])
def test_unsafe_ids_are_refused(tmp_path: Path, bad: str) -> None:
    with pytest.raises(SceneError) as e:
        SceneLibrary(tmp_path).write(bad, "points.ply", _points())
    assert e.value.status == 400


def test_only_the_two_scene_files_are_served(tmp_path: Path) -> None:
    with pytest.raises(SceneError) as e:
        SceneLibrary(tmp_path).read("bench", "secrets.txt")
    assert e.value.status == 404


@pytest.mark.parametrize(
    "manifest",
    [
        b"not json",
        json.dumps({"format": "other"}).encode(),
        json.dumps(_manifest(version=99)).encode(),
        json.dumps(_manifest(frameId="map")).encode(),
    ],
)
def test_bad_manifests_are_refused(tmp_path: Path, manifest: bytes) -> None:
    with pytest.raises(SceneError):
        SceneLibrary(tmp_path).write("s", "scene.json", manifest)


def test_bad_points_are_refused(tmp_path: Path) -> None:
    with pytest.raises(SceneError):
        SceneLibrary(tmp_path).write("s", "points.ply", b"nope")


async def test_http_push_list_pull_publish_delete(tmp_path: Path) -> None:
    published = []

    async def on_publish(scene_id: str) -> dict:
        published.append(scene_id)
        return {"points": 1}

    app = make_app(Handlers(scenes=SceneLibrary(tmp_path), on_publish_scene=on_publish))
    async with TestClient(TestServer(app)) as c:
        assert (await c.put("/v0/scenes/s1/points.ply", data=_points())).status == 200
        assert (await c.put("/v0/scenes/s1/scene.json", data=json.dumps(_manifest()))).status == 200
        listing = await (await c.get("/v0/scenes")).json()
        assert [r["id"] for r in listing["scenes"]] == ["s1"]
        assert await (await c.get("/v0/scenes/s1/points.ply")).read() == _points()
        assert (await c.post("/v0/scenes/s1/publish")).status == 200
        assert published == ["s1"]
        assert (await c.put("/v0/scenes/s1/scene.json", data=b"junk")).status == 400
        assert (await c.delete("/v0/scenes/s1")).status == 200
        assert (await c.get("/v0/scenes/s1/scene.json")).status == 404


async def test_scene_routes_are_501_when_unwired() -> None:
    async with TestClient(TestServer(make_app(Handlers()))) as c:
        assert (await c.get("/v0/scenes")).status == 501
