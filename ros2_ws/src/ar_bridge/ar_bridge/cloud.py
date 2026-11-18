"""Turns a decoded PLY cloud (`ply.DecodedCloud`) into a latched `sensor_msgs/PointCloud2` and a
`.pcd` file on disk. rclpy-free except for the message types, which import fine standalone —
kept this way so it's unit-testable without a live ROS graph, same pattern as `mesh_resolver.py`.
"""

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sensor_msgs.msg import PointCloud2, PointField
from sensor_msgs_py import point_cloud2 as pc2
from std_msgs.msg import Header

from ar_bridge.ply import DecodedCloud


@dataclass
class CloudResult:
    message: PointCloud2
    pcd_path: Path
    point_count: int


def build_point_cloud2(cloud: DecodedCloud, *, frame_id: str, stamp) -> PointCloud2:
    header = Header(frame_id=frame_id, stamp=stamp)
    fields = [
        PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
        PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
        PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
    ]
    rows = [cloud.xyz[:, 0], cloud.xyz[:, 1], cloud.xyz[:, 2]]

    if cloud.confidence is not None:
        fields.append(PointField(name="confidence", offset=12, datatype=PointField.UINT8, count=1))
        rows.append(cloud.confidence.astype(np.uint8))
    if cloud.color is not None:
        # Packed-RGB convention PCL/RViz2's "RGB8" color transformer expects: a FLOAT32 field
        # named "rgb" whose bit pattern is 0x00RRGGBB.
        offset = 16 if cloud.confidence is not None else 12
        fields.append(PointField(name="rgb", offset=offset, datatype=PointField.FLOAT32, count=1))
        packed = (
            cloud.color[:, 0].astype(np.uint32) << 16
            | cloud.color[:, 1].astype(np.uint32) << 8
            | cloud.color[:, 2].astype(np.uint32)
        )
        rows.append(packed.view(np.float32))

    points = list(zip(*rows, strict=True))
    return pc2.create_cloud(header, fields, points)


def write_pcd(cloud: DecodedCloud, path: Path) -> None:
    """Minimal ASCII PCD (v0.7) — readable by pcl_viewer, CloudCompare, open3d, etc."""
    path.parent.mkdir(parents=True, exist_ok=True)
    n = cloud.count
    lines = [
        "# .PCD v0.7 - Point Cloud Data file format",
        "VERSION 0.7",
        "FIELDS x y z",
        "SIZE 4 4 4",
        "TYPE F F F",
        "COUNT 1 1 1",
        f"WIDTH {n}",
        "HEIGHT 1",
        "VIEWPOINT 0 0 0 1 0 0 0",
        f"POINTS {n}",
        "DATA ascii",
    ]
    with path.open("w") as f:
        f.write("\n".join(lines) + "\n")
        # A Python-level per-point f-string loop took ~2s at 1M points (measured) — almost all
        # of this function's cost and most of the whole ingest. np.savetxt formats in C instead.
        np.savetxt(f, cloud.xyz, fmt="%.9g")


def ingest(
    cloud: DecodedCloud, *, frame_id: str, output_dir: Path, name: str, clock_now
) -> CloudResult:
    """`name` is the file stem; the caller owns defaulting it (e.g. to a timestamp) since that
    policy also decides the `mode=append` accumulation key — see `node.py`."""
    pcd_path = output_dir / f"{name}.pcd"
    write_pcd(cloud, pcd_path)
    message = build_point_cloud2(cloud, frame_id=frame_id, stamp=clock_now)
    return CloudResult(message=message, pcd_path=pcd_path, point_count=cloud.count)
