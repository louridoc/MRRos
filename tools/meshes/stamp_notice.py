"""Write a copyright notice into USDZ files' metadata (layer `documentation` and
`customLayerData.copyright`), keeping everything else (geometry, textures) as is.

Why: tools/meshes/convert.py turns the robots' DAE meshes into USDZ, and the conversion drops the
DAE's embedded <copyright>. Universal Robots' terms for the UR20/UR30 meshes forbid removing their
notice, so it is written back here.

Needs OpenUSD's Python API (not in the ROS env):
  uvx --from usd-core python tools/meshes/stamp_notice.py "<notice>" file.usdz [...]
"""

import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

from pxr import Sdf, UsdUtils


def stamp(usdz: Path, notice: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        with zipfile.ZipFile(usdz) as z:
            names = z.namelist()
            z.extractall(work)
        roots = [n for n in names if n.endswith((".usdc", ".usda")) and "/" not in n]
        if len(roots) != 1:
            raise SystemExit(f"{usdz}: expected one root layer, found {roots}")
        layer = Sdf.Layer.FindOrOpen(str(work / roots[0]))
        layer.documentation = notice
        data = dict(layer.customLayerData)
        data["copyright"] = notice
        layer.customLayerData = data
        if not layer.Save():
            raise SystemExit(f"{usdz}: could not save the edited layer")
        out = work / "stamped.usdz"
        if not UsdUtils.CreateNewUsdzPackage(str(work / roots[0]), str(out)):
            raise SystemExit(f"{usdz}: repackaging failed")
        with zipfile.ZipFile(out) as z:
            missing = set(names) - set(z.namelist())
        if missing:
            raise SystemExit(f"{usdz}: repackaged file lost {sorted(missing)}")
        shutil.copyfile(out, usdz)


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    notice = sys.argv[1]
    for path in sys.argv[2:]:
        stamp(Path(path), notice)
        print(f"stamped {path}")


if __name__ == "__main__":
    main()
