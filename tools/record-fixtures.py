#!/usr/bin/env python3
"""Record real rosbridge frames from a running dev bringup into Swift test fixtures.

Usage (inside a distro env, bringup running):
  tools/ros.sh jazzy python tools/record-fixtures.py [ws://localhost:9090] [out_dir]

Writes one JSON file per interaction into ios/Packages/ROSBridgeClient/Tests/Fixtures/.
Re-run per distro if the wire format ever differs; the Swift tests replay these verbatim.
"""

import asyncio
import json
import os
import socket
import sys
import time
from collections.abc import Callable

import aiohttp

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://localhost:9090"
OUT = (
    sys.argv[2]
    if len(sys.argv) > 2
    else os.path.join(
        os.path.dirname(__file__), "..", "ios", "Packages", "ROSBridgeClient", "Tests", "Fixtures"
    )
)


def wait_for_port(host: str, port: int, timeout: float = 60) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError:
            time.sleep(1)
    raise SystemExit(f"rosbridge not reachable at {host}:{port}")


def save(name: str, obj: dict) -> None:
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"{name}.json")
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"wrote {os.path.relpath(path)}  ({len(json.dumps(obj))} bytes)")


async def recv_until(
    ws: aiohttp.ClientWebSocketResponse, pred: Callable[[dict], bool], timeout: float = 15
) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        m = await ws.receive(timeout=deadline - time.time())
        if m.type != aiohttp.WSMsgType.TEXT:
            continue
        d = json.loads(m.data)
        if pred(d):
            return d
    raise TimeoutError("no matching frame")


async def main() -> None:
    host, port = URL.replace("ws://", "").split(":")
    wait_for_port(host, int(port))
    async with aiohttp.ClientSession() as s, s.ws_connect(URL, timeout=10) as ws:
        # 1. rosapi topics service
        await ws.send_json({"op": "call_service", "service": "/rosapi/topics", "id": "svc_topics"})
        save("service_response_topics", await recv_until(ws, lambda d: d.get("id") == "svc_topics"))

        # 2. one JointState publish
        sub = {
            "op": "subscribe",
            "topic": "/joint_states",
            "type": "sensor_msgs/msg/JointState",
            "id": "sub_js",
            "queue_length": 1,
        }
        await ws.send_json(sub)
        save(
            "publish_joint_states",
            await recv_until(
                ws, lambda d: d.get("op") == "publish" and d["topic"] == "/joint_states"
            ),
        )
        await ws.send_json({"op": "unsubscribe", "topic": "/joint_states", "id": "sub_js"})

        # 3. /tf (dynamic) and /tf_static (latched)
        for topic, name in (("/tf", "publish_tf"), ("/tf_static", "publish_tf_static")):
            await ws.send_json(
                {
                    "op": "subscribe",
                    "topic": topic,
                    "type": "tf2_msgs/msg/TFMessage",
                    "id": "sub" + topic,
                }
            )
            save(
                name,
                await recv_until(
                    ws, lambda d, t=topic: d.get("op") == "publish" and d["topic"] == t
                ),
            )
            await ws.send_json({"op": "unsubscribe", "topic": topic, "id": "sub" + topic})

        # 4. /robot_description (transient_local) — rosbridge should match publisher durability
        await ws.send_json(
            {
                "op": "subscribe",
                "topic": "/robot_description",
                "type": "std_msgs/msg/String",
                "id": "sub_rd",
            }
        )
        try:
            rd = await recv_until(
                ws,
                lambda d: d.get("op") == "publish" and d["topic"] == "/robot_description",
                timeout=10,
            )
            rd["msg"]["data"] = (
                rd["msg"]["data"][:2000] + "\n<!-- truncated for fixture -->\n</robot>"
            )
            save("publish_robot_description", rd)
        except TimeoutError:
            print("WARNING: /robot_description not received via subscribe (durability mismatch?)")
        await ws.send_json({"op": "unsubscribe", "topic": "/robot_description", "id": "sub_rd"})

        # 5. get_parameters service fallback for robot_description
        await ws.send_json(
            {
                "op": "call_service",
                "service": "/robot_state_publisher/get_parameters",
                "type": "rcl_interfaces/srv/GetParameters",
                "args": {"names": ["robot_description"]},
                "id": "svc_param",
            }
        )
        resp = await recv_until(ws, lambda d: d.get("id") == "svc_param")
        if resp.get("result") and resp["values"]["values"]:
            v = resp["values"]["values"][0]
            if v.get("string_value"):
                v["string_value"] = (
                    v["string_value"][:2000] + "\n<!-- truncated for fixture -->\n</robot>"
                )
        save("service_response_get_parameters", resp)

        # 6. a status error (unknown service)
        await ws.send_json({"op": "call_service", "service": "/does/not/exist", "id": "svc_bad"})
        save(
            "status_or_error_response",
            await recv_until(ws, lambda d: d.get("op") == "status" or d.get("id") == "svc_bad"),
        )

        # 7. subscribe with throttle + fragment-free small message: /tf_static again via rosapi
        await ws.send_json(
            {"op": "call_service", "service": "/rosapi/get_topics_and_raw_types", "id": "svc_types"}
        )
        save(
            "service_response_topics_and_raw_types",
            await recv_until(ws, lambda d: d.get("id") == "svc_types"),
        )


asyncio.run(main())
