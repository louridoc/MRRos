"""Resolves `package://` mesh URIs to OBJ bytes the app can load directly.

Kept `rclpy`-free (ament_index_python works standalone) so it is unit-testable without a live
ROS graph, same pattern as `http_api.py`. See `docs/protocols/ar_bridge_http.md` for the wire
contract.

Why OBJ, not USDZ: RealityKit's `Entity(contentsOf:)` refuses `.dae`/`.stl` outright on both
iOS and macOS ("noImporter"), but loads `.obj` directly with no up-axis reinterpretation —
unlike COLLADA through SceneKit, which needs the 90°-about-X correction in
`tools/meshes/usdz_convert.swift`. Converting server-side with `trimesh` sidesteps that whole
class of bug for network-fetched meshes, and lets this node run on a Linux lab PC with no
Apple frameworks at all.
"""

import hashlib
from pathlib import Path

try:
    from ament_index_python.packages import PackageNotFoundError, get_package_share_directory
except ImportError:  # pragma: no cover - only hit outside a sourced ROS env

    class PackageNotFoundError(Exception):
        pass

    def get_package_share_directory(_name: str) -> str:
        raise PackageNotFoundError("ament_index_python not available (ROS env not sourced?)")


class MeshResolverError(Exception):
    """Carries the HTTP status http_api.py should respond with."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


# Extensions RealityKit's Entity(contentsOf:) already loads with no conversion needed.
PASSTHROUGH_EXTS = {".obj"}
# Extensions trimesh can read that need converting to .obj for the app to load them.
CONVERTIBLE_EXTS = {".dae", ".stl", ".ply"}


def parse_uri(uri: str) -> tuple[str, str]:
    """`package://pkg/relative/path` -> (pkg, relative/path)."""
    prefix = "package://"
    if not uri.startswith(prefix):
        raise MeshResolverError(400, f"not a package:// uri: {uri!r}")
    rest = uri[len(prefix) :]
    if "/" not in rest:
        raise MeshResolverError(400, f"missing path after package name: {uri!r}")
    package, rel = rest.split("/", 1)
    if not package or not rel:
        raise MeshResolverError(400, f"empty package or path: {uri!r}")
    if ".." in Path(rel).parts:
        raise MeshResolverError(400, f"path traversal rejected: {uri!r}")
    return package, rel


def resolve_source(uri: str) -> Path:
    """`package://...` -> absolute path of the source file on disk."""
    package, rel = parse_uri(uri)
    try:
        share = get_package_share_directory(package)
    except PackageNotFoundError as e:
        raise MeshResolverError(404, f"package {package!r} not found") from e
    path = Path(share) / rel
    if not path.is_file():
        raise MeshResolverError(404, f"no file at {path}")
    return path


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class MeshCache:
    """Converts convertible formats to `.obj` with trimesh and caches the result on disk,
    keyed by the SOURCE file's content hash — an upstream description-package update is
    picked up automatically, and concurrent requests for the same mesh share one conversion
    (the write is atomic via a temp-file rename).
    """

    def __init__(self, cache_dir: str | Path) -> None:
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def obj_bytes(self, source: Path, source_sha256: str) -> bytes:
        ext = source.suffix.lower()
        if ext in PASSTHROUGH_EXTS:
            return source.read_bytes()
        if ext not in CONVERTIBLE_EXTS:
            raise MeshResolverError(415, f"unsupported mesh format: {ext}")

        cached = self.cache_dir / f"{source_sha256}.obj"
        if cached.exists():
            return cached.read_bytes()

        import trimesh  # deferred: heavy import, only paid on an actual conversion

        scene = trimesh.load(str(source), force="scene")
        tmp = cached.with_name(cached.name + ".tmp")
        # file_type explicit: trimesh infers format from the path's trailing extension, which
        # would be ".tmp" for an atomic-write temp file otherwise.
        scene.export(str(tmp), file_type="obj")
        tmp.replace(cached)
        return cached.read_bytes()


def resolve_mesh(uri: str, cache: MeshCache) -> tuple[bytes, str, str]:
    """(obj_bytes, content_type, source_sha256). Raises MeshResolverError for 4xx cases."""
    source = resolve_source(uri)
    sha = sha256_of(source)
    data = cache.obj_bytes(source, sha)
    return data, "model/obj", sha
