"""MoveIt collision objects from the app's scan mesh (M5c). The input cuMotion uses too.

Imports moveit_msgs lazily: ar_bridge stays usable on a machine without MoveIt; the mesh endpoint
then answers 501.
"""

from ar_bridge.mesh_ply import DecodedMesh


def moveit_available() -> bool:
    try:
        import moveit_msgs.msg  # noqa: F401
    except ImportError:
        return False
    return True


def collision_object(mesh: DecodedMesh | None, *, frame_id: str, object_id: str):
    """ADD (MoveIt replaces an existing object with the same id) or, for `mesh=None`, REMOVE."""
    from geometry_msgs.msg import Point, Pose
    from moveit_msgs.msg import CollisionObject
    from shape_msgs.msg import Mesh, MeshTriangle

    obj = CollisionObject()
    obj.header.frame_id = frame_id  # stamp 0: latest transform, as for the clouds
    obj.id = object_id
    obj.pose.orientation.w = 1.0
    if mesh is None:
        obj.operation = CollisionObject.REMOVE
        return obj
    shape = Mesh()
    shape.vertices = [Point(x=x, y=y, z=z) for x, y, z in mesh.vertices.astype(float).tolist()]
    shape.triangles = [MeshTriangle(vertex_indices=t) for t in mesh.triangles.tolist()]
    obj.meshes = [shape]
    obj.mesh_poses = [Pose()]
    obj.mesh_poses[0].orientation.w = 1.0
    obj.operation = CollisionObject.ADD
    return obj


def apply_request(obj):
    """ApplyPlanningScene request carrying one object as a scene diff."""
    from moveit_msgs.srv import ApplyPlanningScene

    req = ApplyPlanningScene.Request()
    req.scene.is_diff = True
    req.scene.robot_state.is_diff = True
    req.scene.world.collision_objects = [obj]
    return req
