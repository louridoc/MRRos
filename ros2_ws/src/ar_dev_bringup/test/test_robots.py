from ar_dev_bringup import distro
from ar_dev_bringup.robots import DEFAULT_ROBOT, ROBOTS


def test_priority_robots_present():
    for key in ("crx30ia", "crx20ial", "ur30", "ur20", "ur10e"):
        assert key in ROBOTS, key


def test_default_is_known():
    assert DEFAULT_ROBOT in ROBOTS


def test_specs_consistent():
    for spec in ROBOTS.values():
        assert spec.joint_names, spec.key
        assert spec.xacro_relpath.endswith(".xacro"), spec.key
        assert spec.vendor in ("ur", "fanuc"), spec.key


def test_distro_helpers(monkeypatch):
    monkeypatch.setattr(distro, "ROS_DISTRO", "jazzy")
    assert distro.check_supported() == "jazzy"
    assert distro.is_at_least("humble")
    assert distro.is_at_least("jazzy")
    assert not distro.is_at_least("lyrical")

    monkeypatch.setattr(distro, "ROS_DISTRO", "foxy")
    try:
        distro.check_supported()
    except RuntimeError as e:
        assert "foxy" in str(e)
    else:
        raise AssertionError("unsupported distro must raise")
