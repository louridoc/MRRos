"""Plays a joint trajectory back as positions over time — the core of mock_joints' fake
FollowJointTrajectory controller. rclpy-free so it's unit-testable on its own.

Linear interpolation between points is enough: MoveIt sends densely time-parameterized
trajectories, and this only drives a simulated robot (dev bringup), never real hardware.
"""

from bisect import bisect_right
from dataclasses import dataclass


@dataclass(frozen=True)
class TrajectoryPlayback:
    joint_names: list[str]
    times: list[float]  # seconds from start, non-decreasing
    rows: list[list[float]]  # one position per joint_names entry, per time

    @staticmethod
    def from_points(joint_names: list[str], points: list[tuple[float, list[float]]]):
        if not points:
            raise ValueError("trajectory has no points")
        times = [float(t) for t, _ in points]
        rows = [[float(v) for v in row] for _, row in points]
        if any(b < a for a, b in zip(times, times[1:], strict=False)):
            raise ValueError("trajectory times must be non-decreasing")
        if any(len(r) != len(joint_names) for r in rows):
            raise ValueError("every point needs one of positions per trajectory joint")
        return TrajectoryPlayback(list(joint_names), times, rows)

    def check_against(self, node_joints: list[str]) -> None:
        unknown = [n for n in self.joint_names if n not in node_joints]
        if unknown:
            raise ValueError(f"trajectory has unknown joint(s) {unknown}")

    @property
    def duration(self) -> float:
        return self.times[-1]

    def done(self, t: float) -> bool:
        return t >= self.duration

    def sample(self, t: float) -> list[float]:
        """Positions (trajectory joint order) at `t` seconds; clamps outside [first, last]."""
        if t <= self.times[0]:
            return list(self.rows[0])
        if t >= self.times[-1]:
            return list(self.rows[-1])
        i = bisect_right(self.times, t)  # times[i-1] <= t < times[i]
        t0, t1 = self.times[i - 1], self.times[i]
        a, b = self.rows[i - 1], self.rows[i]
        f = (t - t0) / (t1 - t0) if t1 > t0 else 1.0
        return [x + f * (y - x) for x, y in zip(a, b, strict=True)]

    def positions_for(self, node_joints: list[str], current: list[float], t: float) -> list[float]:
        """Full node-order position vector at `t`: trajectory joints sampled, others unchanged."""
        sampled = dict(zip(self.joint_names, self.sample(t), strict=True))
        return [sampled.get(n, c) for n, c in zip(node_joints, current, strict=True)]
