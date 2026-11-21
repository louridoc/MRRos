from ar_bridge.late_join import LateJoinWatcher


def test_new_subscriber_schedules_one_republish_after_the_delay() -> None:
    w = LateJoinWatcher(delay_s=3.0)
    assert w.observe(10.0, ["move_group"])
    assert not w.due(12.9)
    assert w.due(13.0)
    assert not w.due(14.0)  # fires once


def test_nothing_new_schedules_nothing() -> None:
    w = LateJoinWatcher(delay_s=3.0)
    w.observe(0.0, ["a"])
    w.due(3.0)
    assert not w.observe(5.0, ["a"])
    assert not w.due(100.0)


def test_restart_appears_as_a_new_id_and_schedules_again() -> None:
    w = LateJoinWatcher(delay_s=1.0)
    w.observe(0.0, ["gid-1"])
    assert w.due(1.0)
    w.observe(5.0, [])  # move_group gone
    assert w.observe(6.0, ["gid-2"])  # back, new endpoint
    assert w.due(7.0)


def test_joiners_in_a_row_are_debounced_into_one_republish() -> None:
    w = LateJoinWatcher(delay_s=3.0)
    w.observe(0.0, ["a"])
    w.observe(2.0, ["a", "b"])
    assert not w.due(3.0)  # pushed back by b
    assert w.due(5.0)
    assert not w.due(6.0)


def test_a_vanished_subscriber_that_returns_with_the_same_id_counts_as_new() -> None:
    w = LateJoinWatcher(delay_s=0.0)
    w.observe(0.0, ["a"])
    w.due(0.0)
    w.observe(1.0, [])
    assert w.observe(2.0, ["a"])
