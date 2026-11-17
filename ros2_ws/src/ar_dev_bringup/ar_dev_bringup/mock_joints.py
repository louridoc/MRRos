"""Publish slowly-moving sinusoidal /joint_states so the AR robot visibly animates.

Parameters:
  joint_names (string[])  joints to animate
  rate_hz (double)        publish rate, default 30
  amplitude_rad (double)  peak excursion, default 0.6
  period_s (double)       full cycle, default 12
  frozen (bool)           publish zeros only (useful for FK tests), default false
  positions (double[])    if non-empty, publish exactly these constant positions (FK fixtures)
"""

import math

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import JointState


class MockJoints(Node):
    def __init__(self) -> None:
        super().__init__("mock_joints")
        self.declare_parameter("joint_names", ["J1"])
        self.declare_parameter("rate_hz", 30.0)
        self.declare_parameter("amplitude_rad", 0.6)
        self.declare_parameter("period_s", 12.0)
        self.declare_parameter("frozen", False)
        self.declare_parameter("positions", [0.0])

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

        self._pub = self.create_publisher(JointState, "joint_states", 10)
        self._t0 = self.get_clock().now()
        self.create_timer(1.0 / rate, self._tick)
        self.get_logger().info(f"animating {self._names} at {rate} Hz (frozen={self._frozen})")

    def _tick(self) -> None:
        t = (self.get_clock().now() - self._t0).nanoseconds * 1e-9
        msg = JointState()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.name = self._names
        if self._fixed:
            msg.position = list(self._fixed)
        elif self._frozen:
            msg.position = [0.0] * len(self._names)
        else:
            # Phase-shift each joint so the arm sweeps rather than pumps.
            msg.position = [
                self._amp * math.sin(2 * math.pi * t / self._period + i * 0.7)
                for i in range(len(self._names))
            ]
        self._pub.publish(msg)


def main() -> None:
    rclpy.init()
    node = MockJoints()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()
