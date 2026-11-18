import pytest

from ar_dev_bringup.trajectory_playback import TrajectoryPlayback

NAMES = ["a", "b", "c"]


def traj(times, rows, names=("a", "b", "c")):
    return TrajectoryPlayback.from_points(list(names), list(zip(times, rows, strict=True)))


def test_before_start_and_at_t0_is_the_first_point():
    p = traj([0.0, 1.0], [[0, 0, 0], [1, 2, 3]])
    assert p.sample(-1.0) == pytest.approx([0, 0, 0])
    assert p.sample(0.0) == pytest.approx([0, 0, 0])


def test_interpolates_linearly_between_points():
    p = traj([0.0, 1.0, 3.0], [[0, 0, 0], [1, 2, 3], [3, 2, 1]])
    assert p.sample(0.5) == pytest.approx([0.5, 1.0, 1.5])
    assert p.sample(2.0) == pytest.approx([2.0, 2.0, 2.0])


def test_holds_the_last_point_after_the_end_and_reports_done():
    p = traj([0.0, 1.0], [[0, 0, 0], [1, 2, 3]])
    assert not p.done(0.99)
    assert p.done(1.0)
    assert p.sample(5.0) == pytest.approx([1, 2, 3])


def test_first_point_after_zero_starts_from_its_own_value():
    # MoveIt's first point is usually at t=0, but don't extrapolate if it isn't.
    p = traj([0.5, 1.5], [[1, 1, 1], [2, 2, 2]])
    assert p.sample(0.0) == pytest.approx([1, 1, 1])
    assert p.sample(1.0) == pytest.approx([1.5, 1.5, 1.5])


def test_maps_trajectory_joint_order_onto_the_node_order():
    p = traj([0.0, 1.0], [[30, 10, 20], [30, 10, 20]], names=("c", "a", "b"))
    assert p.positions_for(NAMES, current=[0, 0, 0], t=0.5) == pytest.approx([10, 20, 30])


def test_joints_missing_from_the_trajectory_keep_their_current_value():
    p = traj([0.0, 1.0], [[5.0], [7.0]], names=("b",))
    assert p.positions_for(NAMES, current=[1, 2, 3], t=1.0) == pytest.approx([1, 7, 3])


def test_rejects_unknown_joints_empty_and_unsorted_trajectories():
    with pytest.raises(ValueError, match="unknown joint"):
        traj([0.0], [[1]], names=("zz",)).check_against(NAMES)
    with pytest.raises(ValueError, match="no points"):
        TrajectoryPlayback.from_points(NAMES, [])
    with pytest.raises(ValueError, match="non-decreasing"):
        traj([0.0, 2.0, 1.0], [[0, 0, 0], [1, 1, 1], [2, 2, 2]])
    with pytest.raises(ValueError, match="positions"):
        traj([0.0], [[1, 2]])
