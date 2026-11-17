#!/usr/bin/env python3
"""Record per-robot FK fixtures: expanded URDF + matching /tf, /tf_static, /joint_states.

For each robot the dev bringup is launched headless with a fixed, non-trivial joint pose, the
frames are captured over rosbridge, and everything is written to
ios/Packages/URDFKit/Tests/Fixtures/<robot>/. The Swift FK test replays these.

Usage: tools/ros.sh jazzy python tools/record-robot-fixtures.py [robot ...]
"""

import asyncio
import json
import os
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Callable

import aiohttp

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "ios", "Packages", "URDFKit", "Tests", "Fixtures")
URL = "ws://localhost:9090"

# Deterministic, asymmetric pose so every joint contributes a distinct transform.
POSE = [0.3, -0.7, 0.5, -0.2, 0.9, -1.1]

ROBOTS = sys.argv[1:] or ["crx30ia", "crx20ial", "ur30", "ur20", "ur10e"]


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


async def recv_until(
    ws: aiohttp.ClientWebSocketResponse, pred: Callable[[dict], bool], timeout: float = 20
) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        m = await ws.receive(timeout=max(0.1, deadline - time.time()))
        if m.type != aiohttp.WSMsgType.TEXT:
            continue
        d = json.loads(m.data)
        if pred(d):
            return d
    raise TimeoutError("no matching frame")


async def capture(robot: str) -> None:
    out = os.path.join(OUT, robot)
    os.makedirs(out, exist_ok=True)
    async with aiohttp.ClientSession() as s, s.ws_connect(URL, timeout=10) as ws:
        for topic, typ, name in (
            ("/robot_description", "std_msgs/msg/String", "robot_description"),
            ("/tf_static", "tf2_msgs/msg/TFMessage", "tf_static"),
            ("/joint_states", "sensor_msgs/msg/JointState", "joint_states"),
            ("/tf", "tf2_msgs/msg/TFMessage", "tf"),
        ):
            await ws.send_json({"op": "subscribe", "topic": topic, "type": typ, "id": "s" + topic})
            frame = await recv_until(
                ws, lambda d, t=topic: d.get("op") == "publish" and d["topic"] == t
            )
            await ws.send_json({"op": "unsubscribe", "topic": topic, "id": "s" + topic})
            if name == "robot_description":
                with open(os.path.join(out, "robot.urdf"), "w") as f:
                    f.write(frame["msg"]["data"])
            else:
                with open(os.path.join(out, f"{name}.json"), "w") as f:
                    json.dump(frame["msg"], f, indent=1, sort_keys=True)
                    f.write("\n")
    with open(os.path.join(out, "pose.json"), "w") as f:
        json.dump({"positions": POSE}, f)
    rel = os.path.relpath(out, ROOT)
    print(f"  wrote {rel}/ (robot.urdf, tf_static.json, joint_states.json, tf.json)")


def main() -> None:
    for robot in ROBOTS:
        print(f"== {robot}")
        if port_open(9090):
            raise SystemExit("port 9090 busy — stop the running bringup first")
        proc = subprocess.Popen(
            [
                "ros2",
                "launch",
                "ar_dev_bringup",
                "dev.launch.py",
                f"robot:={robot}",
                "rviz:=false",
                "positions:=" + ",".join(map(str, POSE)),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            for _ in range(40):
                if port_open(9090):
                    break
                time.sleep(0.5)
            time.sleep(2.0)  # let robot_state_publisher consume the first joint state
            asyncio.run(capture(robot))
        finally:
            os.killpg(proc.pid, signal.SIGINT)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
            for _ in range(20):
                if not port_open(9090):
                    break
                time.sleep(0.5)


main()
