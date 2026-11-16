"""Catalog of supported robots → how to expand their URDF.

Priority order from docs/PLAN.md §3.3. `xacro_args` are passed to `xacro` as key:=value.
`joint_names` are what the mock joint publisher animates (must match the URDF).
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class RobotSpec:
    key: str
    vendor: str
    description_package: str
    xacro_relpath: str
    xacro_args: dict[str, str] = field(default_factory=dict)
    joint_names: tuple[str, ...] = ()
    base_frame: str = "base_link"


_UR_JOINTS = (
    "shoulder_pan_joint",
    "shoulder_lift_joint",
    "elbow_joint",
    "wrist_1_joint",
    "wrist_2_joint",
    "wrist_3_joint",
)

_CRX_JOINTS = ("J1", "J2", "J3", "J4", "J5", "J6")


def _ur(key: str, ur_type: str) -> RobotSpec:
    return RobotSpec(
        key=key,
        vendor="ur",
        description_package="ur_description",
        xacro_relpath="urdf/ur.urdf.xacro",
        xacro_args={"name": "ur", "ur_type": ur_type},
        joint_names=_UR_JOINTS,
    )


def _crx(key: str, xacro_relpath: str) -> RobotSpec:
    # Paths verified against FANUC-CORPORATION/fanuc_description; see tools/external.repos.tsv
    # for the branch pinned per distro. Update here if upstream renames files.
    return RobotSpec(
        key=key,
        vendor="fanuc",
        description_package="fanuc_crx_description",
        xacro_relpath=xacro_relpath,
        xacro_args={},
        joint_names=_CRX_JOINTS,
    )


ROBOTS: dict[str, RobotSpec] = {
    "crx30ia": _crx("crx30ia", "robot/crx30ia.urdf.xacro"),
    "crx20ial": _crx("crx20ial", "robot/crx20ia_l.urdf.xacro"),
    "ur30": _ur("ur30", "ur30"),
    "ur20": _ur("ur20", "ur20"),
    "ur10e": _ur("ur10e", "ur10e"),
    "ur10": _ur("ur10", "ur10"),
    "ur16e": _ur("ur16e", "ur16e"),
}

DEFAULT_ROBOT = "crx30ia"
