"""Dev bringup: robot_state_publisher(<robot>) + mock joints + rosbridge + ar_bridge + rviz.

  ros2 launch ar_dev_bringup dev.launch.py robot:=crx30ia   # crx20ial ur30 ur20 ur10e ...
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur30 rviz:=false frozen:=true
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur30 rviz:=false positions:="0.1,-0.5,0.3,0,0.2,1"
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur16e ar_bridge:=false   # skip ar_bridge
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur10e moveit:=true        # + move_group (M5)

Works unchanged on Humble, Jazzy and Lyrical; distro-specific bits belong in distro.py.
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.conditions import IfCondition
from launch.launch_description_sources import (
    AnyLaunchDescriptionSource,
    PythonLaunchDescriptionSource,
)
from launch.substitutions import Command, LaunchConfiguration, PythonExpression
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue

from ar_dev_bringup.distro import check_supported
from ar_dev_bringup.robots import DEFAULT_ROBOT, ROBOTS


def _setup(context, *args, **kwargs):
    check_supported()
    robot_key = LaunchConfiguration("robot").perform(context)
    spec = ROBOTS[robot_key]

    xacro_path = os.path.join(
        get_package_share_directory(spec.description_package), spec.xacro_relpath
    )
    xacro_cmd = ["xacro ", xacro_path]
    for k, v in spec.xacro_args.items():
        xacro_cmd.append(f" {k}:={v}")
    robot_description = ParameterValue(Command(xacro_cmd), value_type=str)

    rsp = Node(
        package="robot_state_publisher",
        executable="robot_state_publisher",
        parameters=[{"robot_description": robot_description}],
        output="screen",
    )

    positions_arg = LaunchConfiguration("positions").perform(context).strip()
    positions = [float(v) for v in positions_arg.split(",")] if positions_arg else [0.0]
    mock = Node(
        package="ar_dev_bringup",
        executable="mock_joints",
        parameters=[
            {
                "joint_names": list(spec.joint_names),
                "frozen": LaunchConfiguration("frozen"),
                "positions": positions,
            }
        ],
        output="screen",
    )

    rosbridge = IncludeLaunchDescription(
        AnyLaunchDescriptionSource(
            os.path.join(
                get_package_share_directory("rosbridge_server"),
                "launch",
                "rosbridge_websocket_launch.xml",
            )
        ),
        launch_arguments={"port": LaunchConfiguration("rosbridge_port")}.items(),
    )

    # `/v0/cloud` uploads use `frame_id=map` (pre-M4: an AR-session-local frame — see
    # docs/protocols/ar_bridge_http.md) but nothing in this bringup ever published a `map`
    # frame, so RViz silently had no TF path to render `/mrros/static_cloud` at all. Every
    # robot in `robots.py` roots its own TF tree at `world` with no parent (verified for all 7),
    # so an identity `map` → `world` static transform is a safe, uniform placeholder: it never
    # conflicts with a frame that already has a parent, and M4 replaces it with the real
    # alignment transform.
    map_to_world = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        arguments=["--frame-id", "map", "--child-frame-id", "world"],
    )

    rviz = Node(
        package="rviz2",
        executable="rviz2",
        arguments=[
            "-d",
            os.path.join(get_package_share_directory("ar_dev_bringup"), "config", "dev.rviz"),
        ],
        condition=IfCondition(
            PythonExpression(
                [
                    "'",
                    LaunchConfiguration("rviz"),
                    "' == 'true' and '",
                    LaunchConfiguration("moveit"),
                    "' != 'true'",
                ]
            )
        ),
        output="log",
    )

    ar_bridge = Node(
        package="ar_bridge",
        executable="ar_bridge",
        parameters=[{"http_port": LaunchConfiguration("ar_bridge_port")}],
        condition=IfCondition(LaunchConfiguration("ar_bridge")),
        output="screen",
    )

    # move_group + MoveIt's RViz (moveit.launch.py); the dev RViz is skipped when this is on so
    # there aren't two RViz windows.
    moveit = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(
                get_package_share_directory("ar_dev_bringup"), "launch", "moveit.launch.py"
            )
        ),
        launch_arguments={"robot": robot_key, "rviz": LaunchConfiguration("rviz")}.items(),
        condition=IfCondition(LaunchConfiguration("moveit")),
    )
    return [rsp, mock, map_to_world, rosbridge, rviz, ar_bridge, moveit]


def generate_launch_description() -> LaunchDescription:
    return LaunchDescription(
        [
            DeclareLaunchArgument("robot", default_value=DEFAULT_ROBOT, choices=sorted(ROBOTS)),
            DeclareLaunchArgument("rviz", default_value="true"),
            DeclareLaunchArgument("frozen", default_value="false"),
            DeclareLaunchArgument(
                "positions",
                default_value="",
                description="comma-separated constant joint positions",
            ),
            DeclareLaunchArgument("rosbridge_port", default_value="9090"),
            DeclareLaunchArgument(
                "ar_bridge", default_value="true", description="launch ar_bridge too"
            ),
            DeclareLaunchArgument("ar_bridge_port", default_value="8765"),
            DeclareLaunchArgument(
                "moveit", default_value="false", description="also launch move_group (M5)"
            ),
            OpaqueFunction(function=_setup),
        ]
    )
