"""Scene library on the ROS machine (M5c): the same saved scenes the app keeps, stored as one
folder per scene with `scene.json` + `points.ply` (format: docs/protocols/scene_format.md, written
by ios/Packages/SceneLibrary). The app pushes and pulls them over HTTP; `POST .../publish` filters a
scene with its own boxes and publishes it like an upload, so a stored scene can be sent to MoveIt
without the phone.

rclpy-free, so it's unit-testable anywhere.
"""

import json
import re
import shutil
from pathlib import Path

import numpy as np

from ar_bridge.ply import DecodedCloud, PLYError, decode

FORMAT_NAME = "mrros.scene"
FORMAT_VERSION = 1
MANIFEST = "scene.json"
POINTS = "points.ply"
FILES = (MANIFEST, POINTS)

# Folder names the app generates (name slug + date + suffix); anything with a path separator,
# leading dot or "..", is refused.
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


class SceneError(Exception):
    """Carries the HTTP status (same duck-typed `.status` convention as PLYError)."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


def parse_manifest(data: bytes) -> dict:
    try:
        manifest = json.loads(data)
    except (ValueError, UnicodeDecodeError) as e:
        raise SceneError(400, f"scene.json is not JSON: {e}") from e
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT_NAME:
        raise SceneError(400, f"not an {FORMAT_NAME} manifest")
    version = manifest.get("version")
    if not isinstance(version, int) or version > FORMAT_VERSION:
        raise SceneError(400, f"unsupported scene format version {version!r}")
    if manifest.get("frameId") != "base_link":
        raise SceneError(400, "scenes must be in base_link")
    return manifest


class SceneLibrary:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def folder(self, scene_id: str) -> Path:
        if ".." in scene_id or not _ID.match(scene_id):
            raise SceneError(400, f"invalid scene id {scene_id!r}")
        return self.root / scene_id

    def list(self) -> list[dict]:
        """`[{"id": ..., "manifest": {...}}]`, newest first; incomplete folders are skipped."""
        rows = []
        for folder in self.root.iterdir():
            path = folder / MANIFEST
            if not folder.is_dir() or not path.is_file() or not (folder / POINTS).is_file():
                continue
            try:
                manifest = parse_manifest(path.read_bytes())
            except SceneError:
                continue
            rows.append({"id": folder.name, "manifest": manifest})
        rows.sort(key=lambda r: str(r["manifest"].get("createdAt", "")), reverse=True)
        return rows

    def read(self, scene_id: str, name: str) -> bytes:
        path = self._file(scene_id, name)
        if not path.is_file():
            raise SceneError(404, f"{scene_id}/{name} not found")
        return path.read_bytes()

    def write(self, scene_id: str, name: str, data: bytes) -> None:
        """Validates before writing. Clients send points first and the manifest last, so a
        listed scene (manifest + points present) is always complete."""
        if name == MANIFEST:
            parse_manifest(data)
        else:
            try:
                decode(data)
            except PLYError as e:
                raise SceneError(400, f"points.ply: {e}") from e
        path = self._file(scene_id, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(path)  # atomic on POSIX

    def delete(self, scene_id: str) -> None:
        folder = self.folder(scene_id)
        if not folder.is_dir():
            raise SceneError(404, f"scene {scene_id} not found")
        shutil.rmtree(folder)

    def load(self, scene_id: str) -> tuple[dict, DecodedCloud]:
        manifest = parse_manifest(self.read(scene_id, MANIFEST))
        try:
            cloud = decode(self.read(scene_id, POINTS))
        except PLYError as e:
            raise SceneError(500, f"{scene_id}: points.ply unreadable: {e}") from e
        return manifest, cloud

    def _file(self, scene_id: str, name: str) -> Path:
        if name not in FILES:
            raise SceneError(404, f"scenes hold only {', '.join(FILES)}")
        return self.folder(scene_id) / name


# --- Filtering: mirrors SceneFilter/BaseLinkBox/StoredBox in the Swift packages ---------------


def _inside(xyz: np.ndarray, base_from_box: np.ndarray, lo, hi, pad: float = 0.0) -> np.ndarray:
    """Points (N,3, base_link) inside an oriented box, inclusive, grown by `pad` on every side."""
    box_from_base = np.linalg.inv(base_from_box)
    local = xyz @ box_from_base[:3, :3].T + box_from_base[:3, 3]
    lo = np.asarray(lo, dtype=np.float64) - pad
    hi = np.asarray(hi, dtype=np.float64) + pad
    return np.all((local >= lo) & (local <= hi), axis=1)


def _yaw_box(box: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """BaseLinkBox (`center`, `half`, `yaw` about Z) → (base_from_box, min, max)."""
    c, s = np.cos(box["yaw"]), np.sin(box["yaw"])
    m = np.eye(4)
    m[:3, :3] = [[c, -s, 0], [s, c, 0], [0, 0, 1]]
    m[:3, 3] = box["center"]
    half = np.asarray(box["half"], dtype=np.float64)
    return m, -half, half


def _stored_box(box: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """StoredBox: 16 floats, column-major (simd) → row-major numpy."""
    m = np.asarray(box["baseLinkFromBox"], dtype=np.float64).reshape(4, 4).T
    return m, np.asarray(box["min"]), np.asarray(box["max"])


def filter_for_upload(manifest: dict, cloud: DecodedCloud) -> DecodedCloud:
    """The points the app would upload from this scene: drop the scan-time robot (padded),
    exclusion boxes, and anything outside the crop when it's enabled."""
    xyz = cloud.xyz.astype(np.float64)
    drop = np.zeros(len(xyz), dtype=bool)
    pad = float(manifest.get("robotPadding", 0.0))
    for box in manifest.get("robotBoxes", []):
        drop |= _inside(xyz, *_stored_box(box), pad=pad)
    for box in manifest.get("exclusions", []):
        drop |= _inside(xyz, *_yaw_box(box))
    if manifest.get("cropEnabled"):
        drop |= ~_inside(xyz, *_yaw_box(manifest["crop"]))
    keep = ~drop
    return DecodedCloud(
        xyz=cloud.xyz[keep],
        confidence=None if cloud.confidence is None else cloud.confidence[keep],
        color=None if cloud.color is None else cloud.color[keep],
    )
