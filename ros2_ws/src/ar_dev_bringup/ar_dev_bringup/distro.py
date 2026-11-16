"""The single place where ROS distro differences are allowed to live.

Everything else in the ROS packages must be distro-agnostic and Python-3.10-compatible
(Humble). Add a helper here, with a test, when a difference is discovered.
"""

import os

SUPPORTED = ("humble", "jazzy", "lyrical")

ROS_DISTRO = os.environ.get("ROS_DISTRO", "")


def check_supported() -> str:
    """Return the active distro or raise with a clear message."""
    if ROS_DISTRO not in SUPPORTED:
        raise RuntimeError(
            f"ROS_DISTRO={ROS_DISTRO!r} is not supported; expected one of {SUPPORTED}"
        )
    return ROS_DISTRO


def is_at_least(distro: str) -> bool:
    """True if the running distro is `distro` or newer (release order)."""
    return SUPPORTED.index(check_supported()) >= SUPPORTED.index(distro)
