"""Binary little-endian PLY triangle meshes (M5c): the app's filtered ARKit mesh, in base_link.

    ply
    format binary_little_endian 1.0
    element vertex N        (float x, y, z)
    element face M          (list uchar uint vertex_indices — always 3)
    end_header

Mirrors `MeshPLY` in ios/Packages/LiDARScan; change both together
(docs/protocols/ar_bridge_http.md).
"""

from dataclasses import dataclass

import numpy as np

from ar_bridge.ply import PLYError

_HEADER_END = b"end_header\n"
_VERTEX = np.dtype([("x", "<f4"), ("y", "<f4"), ("z", "<f4")])
_FACE = np.dtype([("n", "u1"), ("i", "<u4", (3,))])  # packed: 13 bytes per triangle


@dataclass
class DecodedMesh:
    vertices: np.ndarray  # (N, 3) float32
    triangles: np.ndarray  # (M, 3) uint32

    @property
    def is_empty(self) -> bool:
        return len(self.triangles) == 0


def encode(vertices: np.ndarray, triangles: np.ndarray) -> bytes:
    """For tests and tools; the app has its own encoder."""
    header = (
        "ply\nformat binary_little_endian 1.0\ncomment MRRos scan mesh\n"
        f"element vertex {len(vertices)}\nproperty float x\nproperty float y\nproperty float z\n"
        f"element face {len(triangles)}\nproperty list uchar uint vertex_indices\nend_header\n"
    ).encode()
    v = np.zeros(len(vertices), dtype=_VERTEX)
    v["x"], v["y"], v["z"] = vertices[:, 0], vertices[:, 1], vertices[:, 2]
    f = np.zeros(len(triangles), dtype=_FACE)
    f["n"] = 3
    f["i"] = triangles
    return header + v.tobytes() + f.tobytes()


def decode(data: bytes) -> DecodedMesh:
    end = data.find(_HEADER_END)
    if end == -1:
        raise PLYError(400, "missing end_header")
    try:
        lines = data[:end].decode("ascii").split("\n")
    except UnicodeDecodeError as e:
        raise PLYError(400, "header is not ASCII") from e
    if lines[:2] != ["ply", "format binary_little_endian 1.0"]:
        raise PLYError(400, "expected 'ply' + 'format binary_little_endian 1.0'")

    counts: dict[str, int] = {}
    props: dict[str, list[str]] = {}
    current = None
    for line in lines[2:]:
        parts = line.split()
        if parts[:1] == ["element"] and len(parts) == 3 and parts[2].isdigit():
            current = parts[1]
            counts[current] = int(parts[2])
            props[current] = []
        elif parts[:1] == ["property"] and current is not None:
            props[current].append(" ".join(parts[1:]))
    if props.get("vertex") != ["float x", "float y", "float z"]:
        raise PLYError(400, f"mesh vertices must be float x,y,z; got {props.get('vertex')}")
    if props.get("face") != ["list uchar uint vertex_indices"]:
        got = props.get("face")
        raise PLYError(400, f"faces must be 'list uchar uint vertex_indices'; got {got}")

    n, m = counts["vertex"], counts["face"]
    body = data[end + len(_HEADER_END) :]
    need = n * _VERTEX.itemsize + m * _FACE.itemsize
    if len(body) < need:
        raise PLYError(400, f"expected {need} bytes of mesh data, got {len(body)}")
    v = np.frombuffer(body, dtype=_VERTEX, count=n)
    f = np.frombuffer(body, dtype=_FACE, count=m, offset=n * _VERTEX.itemsize)
    if m and not np.all(f["n"] == 3):
        raise PLYError(400, "only triangles are supported")
    triangles = f["i"].astype(np.uint32)
    if m and int(triangles.max()) >= n:
        raise PLYError(400, "face index out of range")
    vertices = np.stack([v["x"], v["y"], v["z"]], axis=1).astype(np.float32)
    return DecodedMesh(vertices=vertices, triangles=triangles)
