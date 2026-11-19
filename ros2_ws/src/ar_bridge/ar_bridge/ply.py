"""Binary little-endian PLY codec matching
`ios/Packages/LiDARScan/Sources/LiDARScan/PLYCodec.swift` exactly — if the wire format changes,
update both in the same commit (see `docs/protocols/ar_bridge_http.md`).

`decode` is the one path actually exercised by `POST /v0/cloud`; `encode` exists only to build
test fixtures in Python without needing the Swift side.
"""

from dataclasses import dataclass

import numpy as np

_MAGIC = b"ply\n"
_FORMAT = b"format binary_little_endian 1.0\n"
_END_HEADER = b"end_header\n"


class PLYError(Exception):
    """Carries the HTTP status http_api.py should respond with (matches MeshResolverError's
    convention: any exception with a `.status` int attribute maps straight through)."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


@dataclass
class DecodedCloud:
    xyz: np.ndarray  # (N, 3) float32
    confidence: np.ndarray | None  # (N,) uint8, or None
    color: np.ndarray | None  # (N, 3) uint8, or None

    @property
    def count(self) -> int:
        return self.xyz.shape[0]

    @staticmethod
    def empty() -> "DecodedCloud":
        return DecodedCloud(xyz=np.zeros((0, 3), dtype=np.float32), confidence=None, color=None)


def merge(a: "DecodedCloud", b: "DecodedCloud") -> "DecodedCloud":
    """Concatenates `b` onto `a` (for `mode=append`). If only one side has confidence/color,
    the other side's missing values are backfilled (confidence 0, color black) rather than
    dropped — same rule as `PointCloud.append` on the Swift side, for the same reason: losing
    a column silently is worse than an explicit placeholder."""
    xyz = np.concatenate([a.xyz, b.xyz], axis=0)

    confidence: np.ndarray | None = None
    if a.confidence is not None or b.confidence is not None:
        a_conf = a.confidence if a.confidence is not None else np.zeros(a.count, dtype=np.uint8)
        b_conf = b.confidence if b.confidence is not None else np.zeros(b.count, dtype=np.uint8)
        confidence = np.concatenate([a_conf, b_conf], axis=0)

    color: np.ndarray | None = None
    if a.color is not None or b.color is not None:
        a_col = a.color if a.color is not None else np.zeros((a.count, 3), dtype=np.uint8)
        b_col = b.color if b.color is not None else np.zeros((b.count, 3), dtype=np.uint8)
        color = np.concatenate([a_col, b_col], axis=0)

    return DecodedCloud(xyz=xyz, confidence=confidence, color=color)


def encode(
    xyz: np.ndarray, confidence: np.ndarray | None = None, color: np.ndarray | None = None
) -> bytes:
    """Only used to build test fixtures — not on the request path."""
    n = xyz.shape[0]
    header = _MAGIC + _FORMAT + b"comment MRRos static scan\n" + f"element vertex {n}\n".encode()
    header += b"property float x\nproperty float y\nproperty float z\n"
    if confidence is not None:
        header += b"property uchar confidence\n"
    if color is not None:
        header += b"property uchar red\nproperty uchar green\nproperty uchar blue\n"
    header += _END_HEADER

    dtype: list[tuple[str, str]] = [("x", "<f4"), ("y", "<f4"), ("z", "<f4")]
    if confidence is not None:
        dtype.append(("confidence", "u1"))
    if color is not None:
        dtype += [("red", "u1"), ("green", "u1"), ("blue", "u1")]
    rows = np.zeros(n, dtype=dtype)
    rows["x"], rows["y"], rows["z"] = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    if confidence is not None:
        rows["confidence"] = confidence
    if color is not None:
        rows["red"], rows["green"], rows["blue"] = color[:, 0], color[:, 1], color[:, 2]
    return header + rows.tobytes()


def decode(data: bytes) -> DecodedCloud:
    end = data.find(_END_HEADER)
    if end == -1:
        raise PLYError(400, "missing end_header")
    header_end = end + len(_END_HEADER)
    try:
        header = data[:header_end].decode("ascii")
    except UnicodeDecodeError as e:
        raise PLYError(400, "header is not ASCII") from e

    lines = header.split("\n")
    if not lines or lines[0] != "ply":
        raise PLYError(400, "missing 'ply' magic line")
    if len(lines) < 2 or lines[1] != "format binary_little_endian 1.0":
        raise PLYError(400, "expected 'format binary_little_endian 1.0'")

    vertex_count: int | None = None
    properties: list[str] = []
    for line in lines:
        if line.startswith("element vertex"):
            parts = line.split(" ")
            vertex_count = int(parts[-1]) if parts[-1].isdigit() else None
        elif line.startswith("property"):
            properties.append(line.split(" ")[-1])
    if vertex_count is None:
        raise PLYError(400, "missing 'element vertex'")

    has_confidence, has_color = _validate_properties(properties)

    dtype: list[tuple[str, str]] = [("x", "<f4"), ("y", "<f4"), ("z", "<f4")]
    if has_confidence:
        dtype.append(("confidence", "u1"))
    if has_color:
        dtype += [("red", "u1"), ("green", "u1"), ("blue", "u1")]
    row_dtype = np.dtype(dtype)

    body = data[header_end:]
    expected = vertex_count * row_dtype.itemsize
    if len(body) < expected:
        raise PLYError(400, f"expected {expected} bytes of vertex data, got {len(body)}")

    rows = np.frombuffer(body, dtype=row_dtype, count=vertex_count)
    xyz = np.stack([rows["x"], rows["y"], rows["z"]], axis=1).astype(np.float32)
    confidence = rows["confidence"].copy() if has_confidence else None
    color = (
        np.stack([rows["red"], rows["green"], rows["blue"]], axis=1).astype(np.uint8)
        if has_color
        else None
    )
    return DecodedCloud(xyz=xyz, confidence=confidence, color=color)


def _validate_properties(properties: list[str]) -> tuple[bool, bool]:
    """Mirrors PLYCodec.validate(_:) exactly: x,y,z required and first; confidence optional
    next; red,green,blue optional last. Anything else is rejected, not guessed at."""
    rest = list(properties)
    if rest[:3] != ["x", "y", "z"]:
        raise PLYError(400, f"unsupported properties: {properties}")
    rest = rest[3:]
    has_confidence = False
    if rest[:1] == ["confidence"]:
        has_confidence = True
        rest = rest[1:]
    has_color = False
    if rest:
        if rest != ["red", "green", "blue"]:
            raise PLYError(400, f"unsupported properties: {properties}")
        has_color = True
    return has_confidence, has_color
