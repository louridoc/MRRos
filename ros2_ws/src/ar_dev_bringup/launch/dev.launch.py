"""Dev bringup: robot_state_publisher(<robot>) + mock joints + rosbridge + rviz.

  ros2 launch ar_dev_bringup dev.launch.py robot:=crx30ia   # crx20ial ur30 ur20 ur10e ...
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur30 rviz:=false frozen:=true
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur30 rviz:=false positions:="0.1,-0.5,0.3,0,0.2,1"

Works unchanged on Humble, Jazzy and Lyrical; distro-specific bits belong in distro.py.
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.conditions import IfCondition
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import Command, LaunchConfiguration
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

    rviz = Node(
        package="rviz2",
        executable="rviz2",
        arguments=[
            "-d",
            os.path.join(get_package_share_directory("ar_dev_bringup"), "config", "dev.rviz"),
        ],
        condition=IfCondition(LaunchConfiguration("rviz")),
        output="log",
    )

    return [rsp, mock, rosbridge, rviz]


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
            OpaqueFunction(function=_setup),
        ]
    )
