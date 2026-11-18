import struct

import numpy as np
import pytest

from ar_bridge import ply


def f32le(v: float) -> bytes:
    return struct.pack("<f", v)


# --- decode: happy paths ----------------------------------------------------------------------


def test_decode_xyz_only():
    header = b"ply\nformat binary_little_endian 1.0\nelement vertex 2\n"
    header += b"property float x\nproperty float y\nproperty float z\nend_header\n"
    body = f32le(1) + f32le(2) + f32le(3) + f32le(-1) + f32le(-2) + f32le(-3)
    c = ply.decode(header + body)
    assert c.count == 2
    assert np.allclose(c.xyz, [[1, 2, 3], [-1, -2, -3]])
    assert c.confidence is None
    assert c.color is None


def test_decode_xyz_confidence_and_color():
    header = b"ply\nformat binary_little_endian 1.0\nelement vertex 1\n"
    header += (
        b"property float x\nproperty float y\nproperty float z\n"
        b"property uchar confidence\nproperty uchar red\nproperty uchar green\n"
        b"property uchar blue\n"
        b"end_header\n"
    )
    body = f32le(1) + f32le(2) + f32le(3) + bytes([200, 10, 20, 30])
    c = ply.decode(header + body)
    assert c.confidence.tolist() == [200]
    assert c.color.tolist() == [[10, 20, 30]]


def test_decode_empty_cloud():
    header = b"ply\nformat binary_little_endian 1.0\nelement vertex 0\n"
    header += b"property float x\nproperty float y\nproperty float z\nend_header\n"
    c = ply.decode(header)
    assert c.count == 0


# --- decode: error paths ----------------------------------------------------------------------


def test_decode_rejects_missing_end_header():
    with pytest.raises(ply.PLYError) as exc:
        ply.decode(b"ply\nformat binary_little_endian 1.0\nelement vertex 0\n")
    assert exc.value.status == 400


def test_decode_rejects_bad_magic():
    header = b"nope\nformat binary_little_endian 1.0\nelement vertex 0\nend_header\n"
    with pytest.raises(ply.PLYError) as exc:
        ply.decode(header)
    assert exc.value.status == 400
    assert "magic" in str(exc.value)


def test_decode_rejects_wrong_format():
    header = b"ply\nformat ascii 1.0\nelement vertex 0\nend_header\n"
    with pytest.raises(ply.PLYError) as exc:
        ply.decode(header)
    assert "format" in str(exc.value)


def test_decode_rejects_unsupported_property_order():
    header = b"ply\nformat binary_little_endian 1.0\nelement vertex 1\n"
    header += b"property uchar red\nend_header\n" + bytes([1])
    with pytest.raises(ply.PLYError) as exc:
        ply.decode(header)
    assert exc.value.status == 400


def test_decode_rejects_truncated_body():
    header = b"ply\nformat binary_little_endian 1.0\nelement vertex 2\n"
    header += b"property float x\nproperty float y\nproperty float z\nend_header\n"
    body = f32le(1) + f32le(2) + f32le(3)  # only 1 vertex, claimed 2
    with pytest.raises(ply.PLYError) as exc:
        ply.decode(header + body)
    assert exc.value.status == 400


# --- round-trip via our own encode() (fixture-building convenience) ----------------------------


def test_round_trip_via_python_encoder():
    xyz = np.array([[1.5, -2.5, 0.0], [3.0, 3.0, 3.0]], dtype=np.float32)
    confidence = np.array([0, 2], dtype=np.uint8)
    color = np.array([[255, 0, 0], [0, 255, 0]], dtype=np.uint8)
    data = ply.encode(xyz, confidence=confidence, color=color)
    back = ply.decode(data)
    assert np.allclose(back.xyz, xyz)
    assert back.confidence.tolist() == confidence.tolist()
    assert back.color.tolist() == color.tolist()


SWIFT_FIXTURE_HEADER = (
    b"ply\nformat binary_little_endian 1.0\ncomment MRRos static scan\n"
    b"element vertex 2\nproperty float x\nproperty float y\nproperty float z\n"
    b"property uchar confidence\nend_header\n"
)


def test_decodes_a_hand_written_fixture_shaped_like_the_swift_encoders_output():
    # Mirrors ios/Packages/LiDARScan/Tests/LiDARScanTests/PLYCodecTests.swift's
    # encodedHeaderMatchesTheDocumentedFormatExactly — same header shape, decoded here, so a
    # drift between the two encoders' header text would show up as a decode failure, not just
    # a silent mismatch nobody notices until it hits the real app.
    body = (
        f32le(1)
        + f32le(2)
        + f32le(3)
        + bytes([9])
        + f32le(-1)
        + f32le(-2)
        + f32le(-3)
        + bytes([200])
    )
    c = ply.decode(SWIFT_FIXTURE_HEADER + body)
    assert c.count == 2
    assert c.confidence.tolist() == [9, 200]


# --- merge --------------------------------------------------------------------------------------


def test_merge_concatenates_and_backfills_missing_columns():
    a = ply.DecodedCloud(
        xyz=np.array([[0, 0, 0]], dtype=np.float32),
        confidence=np.array([9], dtype=np.uint8),
        color=None,
    )
    b = ply.DecodedCloud(xyz=np.array([[1, 1, 1]], dtype=np.float32), confidence=None, color=None)
    merged = ply.merge(a, b)
    assert merged.count == 2
    assert merged.confidence.tolist() == [9, 0]  # b's missing confidence backfilled as 0
    assert np.allclose(merged.xyz, [[0, 0, 0], [1, 1, 1]])
