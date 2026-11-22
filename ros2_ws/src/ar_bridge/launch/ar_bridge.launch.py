"""ar_bridge on its own, for any workspace (the dev bringup includes this too).

  ros2 launch ar_bridge ar_bridge.launch.py
  ros2 launch ar_bridge ar_bridge.launch.py scenes_dir:=/data/mrros/scenes http_port:=8770
  ros2 launch ar_bridge ar_bridge.launch.py params_file:=/path/to/my_ar_bridge.yaml

Values come from `params_file` (default: this package's config/ar_bridge.yaml); any argument given
on the command line overrides that file. Unset arguments ("") leave the file's value alone.
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

# Overridable parameters and how to convert the launch string.
OVERRIDES: dict[str, type] = {
    "http_port": int,
    "frame_id": str,
    "cloud_topic": str,
    "output_dir": str,
    "scenes_dir": str,
    "mesh_cache_dir": str,
    "clear_octomap_service": str,
    "late_join_delay_s": float,
    "republish_after_s": float,
}

# Sentinel default meaning "not given": "" is a meaningful value for clear_octomap_service.
UNSET = "__unset__"


def _setup(context, *_args, **_kwargs):
    overrides = {}
    for name, kind in OVERRIDES.items():
        value = LaunchConfiguration(name).perform(context)
        if value != UNSET:
            overrides[name] = kind(value)
    return [
        Node(
            package="ar_bridge",
            executable="ar_bridge",
            name="ar_bridge",
            parameters=[LaunchConfiguration("params_file").perform(context), overrides],
            output="screen",
        )
    ]


def generate_launch_description() -> LaunchDescription:
    default_params = os.path.join(
        get_package_share_directory("ar_bridge"), "config", "ar_bridge.yaml"
    )
    return LaunchDescription(
        [
            DeclareLaunchArgument("params_file", default_value=default_params),
            *[
                DeclareLaunchArgument(name, default_value=UNSET, description=f"override {name}")
                for name in OVERRIDES
            ],
            OpaqueFunction(function=_setup),
        ]
    )
