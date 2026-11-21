import numpy as np
import pytest

from ar_bridge.mesh_ply import decode, encode
from ar_bridge.ply import PLYError

VERTS = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]], dtype=np.float32)
TRIS = np.array([[0, 1, 2], [0, 1, 3]], dtype=np.uint32)


def test_round_trip() -> None:
    mesh = decode(encode(VERTS, TRIS))
    np.testing.assert_array_equal(mesh.vertices, VERTS)
    np.testing.assert_array_equal(mesh.triangles, TRIS)
    assert not mesh.is_empty


def test_empty_mesh() -> None:
    assert decode(encode(np.zeros((0, 3), np.float32), np.zeros((0, 3), np.uint32))).is_empty


def test_face_is_13_bytes_packed() -> None:
    data = encode(VERTS, TRIS)
    body = data[data.index(b"end_header\n") + len(b"end_header\n") :]
    assert len(body) == 4 * 12 + 2 * 13


def test_out_of_range_index_is_refused() -> None:
    with pytest.raises(PLYError):
        decode(encode(VERTS, np.array([[0, 1, 9]], dtype=np.uint32)))


def test_truncated_body_is_refused() -> None:
    with pytest.raises(PLYError):
        decode(encode(VERTS, TRIS)[:-5])


def test_a_point_cloud_ply_is_not_a_mesh() -> None:
    from ar_bridge.ply import encode as encode_cloud

    with pytest.raises(PLYError):
        decode(encode_cloud(VERTS))


def test_decodes_the_swift_written_mesh_exactly() -> None:
    """fixtures/mesh_v1.ply comes from LiDARScan's MeshPLY (ScanMeshTests)."""
    from pathlib import Path

    mesh = decode((Path(__file__).parent / "fixtures" / "mesh_v1.ply").read_bytes())
    assert mesh.triangles.tolist() == [[0, 1, 2], [1, 3, 2], [4, 5, 6]]
    assert mesh.vertices.tolist()[5] == [10.0, 9.0, 9.0]
