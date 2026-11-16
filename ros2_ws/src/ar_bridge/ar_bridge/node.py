"""ar_bridge ROS 2 node: runs the aiohttp server beside an rclpy executor.

Parameters:
  http_port (int)        default 8765
  frame_id (string)      frame the published cloud is expressed in, default base_link
  output_dir (string)    where .pcd/.ply files are written, default ~/.mrros/clouds
"""

import os
import threading

import rclpy
from aiohttp import web
from rclpy.node import Node

from ar_bridge.http_api import Handlers, make_app


class ARBridge(Node):
    def __init__(self) -> None:
        super().__init__("ar_bridge")
        self.declare_parameter("http_port", 8765)
        self.declare_parameter("frame_id", "base_link")
        self.declare_parameter("output_dir", os.path.expanduser("~/.mrros/clouds"))

        self.port = int(self.get_parameter("http_port").value)
        self.frame_id = str(self.get_parameter("frame_id").value)
        self.output_dir = str(self.get_parameter("output_dir").value)
        os.makedirs(self.output_dir, exist_ok=True)

        # M0: only /health is live. M2b adds get_mesh, M3 adds on_cloud.
        self.handlers = Handlers()
        self.get_logger().info(
            f"http on :{self.port}, frame_id={self.frame_id}, out={self.output_dir}, "
            f"ROS_DISTRO={os.environ.get('ROS_DISTRO', '?')}"
        )

    def serve_forever(self) -> None:
        app = make_app(self.handlers, node_name=self.get_name())
        web.run_app(app, host="0.0.0.0", port=self.port, print=None, handle_signals=False)


def main() -> None:
    rclpy.init()
    node = ARBridge()
    spin = threading.Thread(target=rclpy.spin, args=(node,), daemon=True)
    spin.start()
    try:
        node.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()
