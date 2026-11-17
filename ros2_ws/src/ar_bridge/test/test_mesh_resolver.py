from pathlib import Path

import pytest

from ar_bridge import mesh_resolver as mr

FIXTURES = Path(__file__).parent / "fixtures"


# --- parse_uri -----------------------------------------------------------------------------


def test_parse_uri_happy_path():
    assert mr.parse_uri("package://pkg/dir/file.dae") == ("pkg", "dir/file.dae")


@pytest.mark.parametrize(
    "uri",
    [
        "http://pkg/file.dae",  # wrong scheme
        "package://",  # nothing at all
        "package://onlypkg",  # no slash, no path
        "package:///nopkg/x.dae",  # empty package name
        "package://pkg/",  # empty path
        "package://pkg/../../etc/passwd",  # traversal
    ],
)
def test_parse_uri_rejects(uri):
    with pytest.raises(mr.MeshResolverError) as exc:
        mr.parse_uri(uri)
    assert exc.value.status == 400


# --- resolve_source --------------------------------------------------------------------------


def test_resolve_source_happy_path(monkeypatch):
    monkeypatch.setattr(mr, "get_package_share_directory", lambda pkg: str(FIXTURES))
    assert mr.resolve_source("package://fake_pkg/tiny.stl") == FIXTURES / "tiny.stl"


def test_resolve_source_unknown_package(monkeypatch):
    def boom(_pkg):
        raise mr.PackageNotFoundError("nope")

    monkeypatch.setattr(mr, "get_package_share_directory", boom)
    with pytest.raises(mr.MeshResolverError) as exc:
        mr.resolve_source("package://ghost/x.dae")
    assert exc.value.status == 404


def test_resolve_source_missing_file(monkeypatch):
    monkeypatch.setattr(mr, "get_package_share_directory", lambda pkg: str(FIXTURES))
    with pytest.raises(mr.MeshResolverError) as exc:
        mr.resolve_source("package://fake_pkg/does_not_exist.dae")
    assert exc.value.status == 404


# --- sha256_of -------------------------------------------------------------------------------


def test_sha256_is_deterministic_and_content_sensitive():
    a = mr.sha256_of(FIXTURES / "tiny.obj")
    b = mr.sha256_of(FIXTURES / "tiny.obj")
    c = mr.sha256_of(FIXTURES / "tiny.stl")
    assert a == b
    assert a != c
    assert len(a) == 64


# --- MeshCache ------------------------------------------------------------------------------


def test_cache_passthrough_for_obj(tmp_path):
    cache = mr.MeshCache(tmp_path)
    data = cache.obj_bytes(FIXTURES / "tiny.obj", "irrelevant-hash")
    assert data == (FIXTURES / "tiny.obj").read_bytes()
    assert list(tmp_path.iterdir()) == []  # no conversion artifact for a passthrough format


def test_cache_rejects_unsupported_extension(tmp_path):
    cache = mr.MeshCache(tmp_path)
    with pytest.raises(mr.MeshResolverError) as exc:
        cache.obj_bytes(FIXTURES / "tiny.obj.unknownext", "hash")
    assert exc.value.status == 415


def test_cache_converts_and_reuses(tmp_path):
    pytest.importorskip("trimesh")
    cache = mr.MeshCache(tmp_path)
    sha = mr.sha256_of(FIXTURES / "tiny.stl")

    first = cache.obj_bytes(FIXTURES / "tiny.stl", sha)
    assert b"v " in first  # looks like OBJ vertex data
    cached_file = tmp_path / f"{sha}.obj"
    assert cached_file.exists()

    mtime_before = cached_file.stat().st_mtime_ns
    second = cache.obj_bytes(FIXTURES / "tiny.stl", sha)
    assert second == first
    assert cached_file.stat().st_mtime_ns == mtime_before  # second call did not reconvert


# --- resolve_mesh (end to end) ----------------------------------------------------------------


def test_resolve_mesh_end_to_end(monkeypatch, tmp_path):
    pytest.importorskip("trimesh")
    monkeypatch.setattr(mr, "get_package_share_directory", lambda pkg: str(FIXTURES))
    cache = mr.MeshCache(tmp_path)

    data, content_type, sha = mr.resolve_mesh("package://fake_pkg/tiny.stl", cache)
    assert content_type == "model/obj"
    assert sha == mr.sha256_of(FIXTURES / "tiny.stl")
    assert b"v " in data


def test_resolve_mesh_propagates_404(monkeypatch, tmp_path):
    monkeypatch.setattr(mr, "get_package_share_directory", lambda pkg: str(FIXTURES))
    cache = mr.MeshCache(tmp_path)
    with pytest.raises(mr.MeshResolverError) as exc:
        mr.resolve_mesh("package://fake_pkg/missing.dae", cache)
    assert exc.value.status == 404
