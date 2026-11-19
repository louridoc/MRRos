"""MoveIt move_group for the dev bringup's robot, with MoveIt's point-cloud octomap updater fed
by ar_bridge's /mrros/static_cloud (see config/sensors_3d.yaml).

execute:=true (default) points MoveIt at mock_joints' fake FollowJointTrajectory controller, so
"Plan & Execute" plays the trajectory onto /joint_states — the RViz robot and the AR robot move.
Simulation only. execute:=false is planning-only (no controllers).

Run alongside the dev bringup, same robot:
  ros2 launch ar_dev_bringup dev.launch.py robot:=ur10e rviz:=false
  ros2 launch ar_dev_bringup moveit.launch.py robot:=ur10e

robot_description is built from the same xacro + args as dev.launch.py's robot_state_publisher,
so MoveIt, TF and the app all see one robot. SRDF/kinematics/limits/OMPL come from the vendor
package named in robots.py (ur_moveit_config, or fanuc_moveit_config from fanuc_driver).
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from moveit_configs_utils import MoveItConfigsBuilder

from ar_dev_bringup.distro import check_supported
from ar_dev_bringup.robots import DEFAULT_ROBOT, ROBOTS


def _setup(context, *args, **kwargs):
    check_supported()
    spec = ROBOTS[LaunchConfiguration("robot").perform(context)]
    here = get_package_share_directory("ar_dev_bringup")
    xacro_path = os.path.join(
        get_package_share_directory(spec.description_package), spec.xacro_relpath
    )

    moveit_config = (
        MoveItConfigsBuilder(spec.key, package_name=spec.moveit_package)
        .robot_description(file_path=xacro_path, mappings=spec.xacro_args)
        .robot_description_semantic(file_path=spec.srdf_relpath, mappings=spec.srdf_args)
        .planning_pipelines(pipelines=["ompl"])
        .trajectory_execution(
            file_path=os.path.join(here, "config", "moveit_controllers_none.yaml"),
            moveit_manage_controllers=False,
        )
        .sensors_3d(file_path=os.path.join(here, "config", "sensors_3d.yaml"))
        .to_moveit_configs()
    )
    # Planning-only setup: drop the Ruckig jerk-limited smoother MoveItConfigsBuilder adds by
    # default. With FANUC's conservative limits (0.4 rad/s², no jerk limits) Ruckig hits its
    # duration cap and fails the whole plan even though OMPL found a valid path; time-optimal
    # parameterization + solution validation remain.
    ompl = moveit_config.planning_pipelines.get("ompl", {})
    ompl["response_adapters"] = [a for a in ompl.get("response_adapters", []) if "Ruckig" not in a]
    # Collision-check motions every 0.2% of the state-space extent, on the group we actually plan
    # with. MoveIt's default 0.5% is ~0.15 rad per check on a UR (±360° joints) — coarse enough
    # that OMPL accepted paths grazing a thin scanned wall, which ValidateSolution then rejected
    # (seen on UR10e and CRX). FANUC's ompl_planning.yaml also keys its settings to group `arm`
    # while its SRDF's group is `manipulator`, so its own value never applied.
    group = ompl.setdefault(spec.planning_group, {})
    group["longest_valid_segment_fraction"] = min(
        group.get("longest_valid_segment_fraction", 0.002), 0.002
    )
    octomap = {
        "octomap_frame": LaunchConfiguration("octomap_frame").perform(context),
        "octomap_resolution": float(LaunchConfiguration("octomap_resolution").perform(context)),
    }

    parameters = [moveit_config.to_dict(), octomap, {"publish_robot_description_semantic": True}]
    if LaunchConfiguration("execute").perform(context) == "true":
        # Later dicts override earlier ones: replaces moveit_controllers_none.yaml's empty manager.
        parameters.append(_mock_controller(list(spec.joint_names)))

    move_group = Node(
        package="moveit_ros_move_group",
        executable="move_group",
        output="screen",
        parameters=parameters,
    )
    rviz = Node(
        package="rviz2",
        executable="rviz2",
        name="rviz2_moveit",
        output="log",
        arguments=["-d", os.path.join(here, "config", "moveit.rviz")],
        parameters=[
            moveit_config.robot_description,
            moveit_config.robot_description_semantic,
            moveit_config.robot_description_kinematics,
            moveit_config.planning_pipelines,
            moveit_config.joint_limits,
        ],
        condition=IfCondition(LaunchConfiguration("rviz")),
    )
    return [move_group, rviz]


def _mock_controller(joints: list[str]) -> dict:
    """MoveIt controller config for mock_joints' fake controller (same name as its default
    `controller_name` parameter)."""
    return {
        "moveit_controller_manager": (
            "moveit_simple_controller_manager/MoveItSimpleControllerManager"
        ),
        "moveit_simple_controller_manager": {
            "controller_names": ["mrros_mock_controller"],
            "mrros_mock_controller": {
                "type": "FollowJointTrajectory",
                "action_ns": "follow_joint_trajectory",
                "default": True,
                "joints": joints,
            },
        },
    }


def generate_launch_description() -> LaunchDescription:
    return LaunchDescription(
        [
            DeclareLaunchArgument("robot", default_value=DEFAULT_ROBOT, choices=sorted(ROBOTS)),
            DeclareLaunchArgument("rviz", default_value="true"),
            DeclareLaunchArgument(
                "execute",
                default_value="true",
                description="fake trajectory execution via mock_joints (false = planning only)",
            ),
            DeclareLaunchArgument("octomap_frame", default_value="base_link"),
            DeclareLaunchArgument("octomap_resolution", default_value="0.02"),
            OpaqueFunction(function=_setup),
        ]
    )
