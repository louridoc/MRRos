"""Publish /joint_states for the dev bringup, and act as a fake FollowJointTrajectory controller.

By default the joints sweep sinusoidally so the AR robot visibly animates; `frozen`/`positions`
hold a fixed pose instead. MoveIt (moveit.launch.py with execute:=true) can also send trajectories
to `<controller_name>/follow_joint_trajectory`: they're played back onto /joint_states and the
final pose is then held, overriding the sweep/frozen/positions modes. Simulation only — this is
the dev bringup's stand-in for a robot driver, never a path to real hardware.

Parameters:
  joint_names (string[])  joints to publish
  rate_hz (double)        publish rate, default 30
  amplitude_rad (double)  peak sweep excursion, default 0.6
  period_s (double)       full sweep cycle, default 12
  frozen (bool)           publish zeros only (useful for FK tests), default false
  positions (double[])    if non-empty, publish exactly these constant positions (FK fixtures)
  controller_name (str)   action namespace for the fake controller, default mrros_mock_controller
"""

import math
import threading
import time

import rclpy
from control_msgs.action import FollowJointTrajectory
from rclpy.action import ActionServer, CancelResponse, GoalResponse
from rclpy.callback_groups import ReentrantCallbackGroup
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from sensor_msgs.msg import JointState

from ar_dev_bringup.trajectory_playback import TrajectoryPlayback


def _playback(traj) -> TrajectoryPlayback:
    points = [
        (p.time_from_start.sec + p.time_from_start.nanosec * 1e-9, list(p.positions))
        for p in traj.points
    ]
    return TrajectoryPlayback.from_points(list(traj.joint_names), points)


class MockJoints(Node):
    def __init__(self) -> None:
        super().__init__("mock_joints")
        self.declare_parameter("joint_names", ["J1"])
        self.declare_parameter("rate_hz", 30.0)
        self.declare_parameter("amplitude_rad", 0.6)
        self.declare_parameter("period_s", 12.0)
        self.declare_parameter("frozen", False)
        self.declare_parameter("positions", [0.0])
        self.declare_parameter("controller_name", "mrros_mock_controller")

        self._names = list(self.get_parameter("joint_names").value)
        self._amp = float(self.get_parameter("amplitude_rad").value)
        self._period = float(self.get_parameter("period_s").value)
        self._frozen = bool(self.get_parameter("frozen").value)
        fixed = [float(v) for v in self.get_parameter("positions").value]
        # [0.0] is the declared default (rclpy needs a typed non-empty default); treat as unset.
        self._fixed = fixed if fixed != [0.0] else []
        if self._fixed and len(self._fixed) != len(self._names):
            raise ValueError(
                f"positions has {len(self._fixed)} values for {len(self._names)} joints"
            )
        rate = float(self.get_parameter("rate_hz").value)
        self._dt = 1.0 / rate

        # Shared between the publish timer and the action's execute thread.
        self._lock = threading.Lock()
        self._t0 = time.monotonic()
        self._current = self._base_positions(0.0)
        self._held: list[float] | None = None  # final pose of the last trajectory
        self._active: tuple[TrajectoryPlayback, float] | None = None  # (playback, start time)
        self._goal_token = 0  # bumped per accepted goal; a stale token means "preempted"

        self._pub = self.create_publisher(JointState, "joint_states", 10)
        self.create_timer(self._dt, self._tick)
        controller = self.get_parameter("controller_name").value
        self._server = ActionServer(
            self,
            FollowJointTrajectory,
            f"{controller}/follow_joint_trajectory",
            execute_callback=self._execute,
            goal_callback=self._on_goal,
            cancel_callback=lambda _goal: CancelResponse.ACCEPT,
            callback_group=ReentrantCallbackGroup(),
        )
        self.get_logger().info(
            f"publishing {self._names} at {rate} Hz (frozen={self._frozen}); "
            f"fake controller on {controller}/follow_joint_trajectory"
        )

    def _base_positions(self, t: float) -> list[float]:
        if self._fixed:
            return list(self._fixed)
        if self._frozen:
            return [0.0] * len(self._names)
        # Phase-shift each joint so the arm sweeps rather than pumps.
        return [
            self._amp * math.sin(2 * math.pi * t / self._period + i * 0.7)
            for i in range(len(self._names))
        ]

    def _tick(self) -> None:
        now = time.monotonic()
        with self._lock:
            if self._active is not None:
                playback, start = self._active
                self._current = playback.positions_for(self._names, self._current, now - start)
            elif self._held is not None:
                self._current = list(self._held)
            else:
                self._current = self._base_positions(now - self._t0)
            positions = list(self._current)
        msg = JointState()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.name = self._names
        msg.position = positions
        self._pub.publish(msg)

    def _on_goal(self, goal_request) -> GoalResponse:
        try:
            _playback(goal_request.trajectory).check_against(self._names)
        except ValueError as e:
            self.get_logger().warning(f"rejecting trajectory: {e}")
            return GoalResponse.REJECT
        return GoalResponse.ACCEPT

    def _execute(self, goal_handle) -> FollowJointTrajectory.Result:
        playback = _playback(goal_handle.request.trajectory)
        with self._lock:
            self._goal_token += 1
            token = self._goal_token
            start = time.monotonic()
            self._active = (playback, start)
        self.get_logger().info(
            f"executing {len(playback.times)}-point trajectory over {playback.duration:.2f} s"
        )
        result = FollowJointTrajectory.Result()
        while True:
            with self._lock:
                if self._goal_token != token:  # a newer goal took over
                    result.error_string = "preempted by a newer trajectory"
                    goal_handle.abort()
                    return result
                if goal_handle.is_cancel_requested:
                    self._active = None
                    self._held = list(self._current)  # stop where it is
                    goal_handle.canceled()
                    return result
                if playback.done(time.monotonic() - start):
                    self._active = None
                    self._held = playback.positions_for(
                        self._names, self._current, playback.duration
                    )
                    self._current = list(self._held)
                    goal_handle.succeed()
                    result.error_code = FollowJointTrajectory.Result.SUCCESSFUL
                    return result
            time.sleep(self._dt)


def main() -> None:
    rclpy.init()
    node = MockJoints()
    # Multi-threaded: the action's execute callback waits for playback while the publish timer
    # keeps producing /joint_states.
    executor = MultiThreadedExecutor()
    executor.add_node(node)
    try:
        executor.spin()
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()
