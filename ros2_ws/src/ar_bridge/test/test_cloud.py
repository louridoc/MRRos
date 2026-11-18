import numpy as np
import pytest

# sensor_msgs/std_msgs need a sourced ROS env; skip this whole file outside one (same pattern
# as the trimesh-dependent tests in test_mesh_resolver.py) rather than erroring on import.
pytest.importorskip("sensor_msgs.msg")

from builtin_interfaces.msg import Time  # noqa: E402

from ar_bridge import cloud  # noqa: E402
from ar_bridge.ply import DecodedCloud  # noqa: E402


def make_cloud(n=3, with_confidence=False, with_color=False) -> DecodedCloud:
    xyz = np.arange(n * 3, dtype=np.float32).reshape(n, 3)
    confidence = np.arange(n, dtype=np.uint8) if with_confidence else None
    color = np.arange(n * 3, dtype=np.uint8).reshape(n, 3) if with_color else None
    return DecodedCloud(xyz=xyz, confidence=confidence, color=color)


def test_build_point_cloud2_xyz_only_has_three_fields_and_right_point_count():
    msg = cloud.build_point_cloud2(make_cloud(4), frame_id="base_link", stamp=Time())
    assert msg.header.frame_id == "base_link"
    assert [f.name for f in msg.fields] == ["x", "y", "z"]
    assert msg.width == 4
    assert msg.height == 1
    assert len(msg.data) == 4 * msg.point_step


def test_build_point_cloud2_round_trips_xyz_through_read_points():
    from sensor_msgs_py import point_cloud2 as pc2

    c = make_cloud(3)
    msg = cloud.build_point_cloud2(c, frame_id="map", stamp=Time())
    read_back = np.array(
        [[p[0], p[1], p[2]] for p in pc2.read_points(msg, field_names=("x", "y", "z"))]
    )
    assert np.allclose(read_back, c.xyz)


def test_build_point_cloud2_with_confidence_and_color_adds_matching_fields():
    c = make_cloud(2, with_confidence=True, with_color=True)
    msg = cloud.build_point_cloud2(c, frame_id="map", stamp=Time())
    names = [f.name for f in msg.fields]
    assert names == ["x", "y", "z", "confidence", "rgb"]


def test_write_pcd_produces_a_readable_ascii_header_and_right_point_count(tmp_path):
    c = make_cloud(5)
    path = tmp_path / "scan.pcd"
    cloud.write_pcd(c, path)
    text = path.read_text()
    assert text.startswith("# .PCD v0.7")
    assert "POINTS 5" in text
    assert "WIDTH 5" in text
    assert "DATA ascii" in text
    # header (11 lines) + 5 data lines
    assert len(text.strip().split("\n")) == 11 + 5


def test_ingest_writes_pcd_and_returns_matching_result(tmp_path):
    c = make_cloud(3)
    result = cloud.ingest(
        c, frame_id="base_link", output_dir=tmp_path, name="myscan", clock_now=Time()
    )
    assert result.point_count == 3
    assert result.pcd_path == tmp_path / "myscan.pcd"
    assert result.pcd_path.exists()
    assert result.message.header.frame_id == "base_link"
