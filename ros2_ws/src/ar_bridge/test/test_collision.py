import numpy as np
import pytest

pytest.importorskip("moveit_msgs")

from ar_bridge.collision import apply_request, collision_object  # noqa: E402
from ar_bridge.mesh_ply import DecodedMesh  # noqa: E402

MESH = DecodedMesh(
    vertices=np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32),
    triangles=np.array([[0, 1, 2]], dtype=np.uint32),
)


def test_add_carries_the_mesh_in_the_given_frame() -> None:
    from moveit_msgs.msg import CollisionObject

    obj = collision_object(MESH, frame_id="base_link", object_id="scan")
    assert obj.operation == CollisionObject.ADD
    assert obj.header.frame_id == "base_link" and obj.id == "scan"
    assert len(obj.meshes[0].vertices) == 3 and obj.meshes[0].vertices[1].x == 1.0
    assert list(obj.meshes[0].triangles[0].vertex_indices) == [0, 1, 2]
    assert obj.mesh_poses[0].orientation.w == 1.0


def test_none_removes() -> None:
    from moveit_msgs.msg import CollisionObject

    obj = collision_object(None, frame_id="base_link", object_id="scan")
    assert obj.operation == CollisionObject.REMOVE and not obj.meshes


def test_apply_request_is_a_diff() -> None:
    req = apply_request(collision_object(MESH, frame_id="base_link", object_id="scan"))
    assert req.scene.is_diff and req.scene.robot_state.is_diff
    assert req.scene.world.collision_objects[0].id == "scan"
