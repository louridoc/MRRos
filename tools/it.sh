#!/usr/bin/env bash
# Integration tests: launch the dev bringup headless for one distro, run ROS pytest + the Swift
# suites that talk to the live rosbridge, tear down.
# Usage: tools/it.sh [distro] [robot]     (defaults: jazzy, ur10e; joints frozen for determinism)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"

distro="$(mrros_distro "${1:-}")"
ROBOT="${2:-ur10e}"
PORT=9090
LOG="$ROOT/ros2_ws/log/it_${distro}.log"
mkdir -p "$(dirname "$LOG")"

port_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

LAUNCH_PATTERN="ros2 launch ar_dev_bringup dev.launch.py"
cleanup() {
  # `micromamba run` wraps the launch, so signal the real `ros2 launch` by pattern: it forwards
  # SIGINT to its nodes and exits cleanly. Escalate only if the port is still open afterwards.
  pkill -INT -f "$LAUNCH_PATTERN" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do port_open "$PORT" || break; sleep 1; done
  if port_open "$PORT"; then
    pkill -TERM -f "rosbridge_websocket --ros-args|rosapi_node|robot_state_publisher --ros-args|ar_dev_bringup/mock_joints" 2>/dev/null || true
    sleep 2
    pkill -KILL -f "$LAUNCH_PATTERN|rosbridge_websocket --ros-args|rosapi_node|robot_state_publisher --ros-args|ar_dev_bringup/mock_joints" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if port_open "$PORT"; then
  echo "port $PORT already in use — stop the running bringup first" >&2
  exit 1
fi

"$ROOT/tools/ros.sh" "$distro" ros2 launch ar_dev_bringup dev.launch.py \
  robot:="$ROBOT" rviz:=false frozen:=true > "$LOG" 2>&1 &
LAUNCH_PID=$!

echo "waiting for rosbridge on :$PORT ($distro, $ROBOT)…"
up=0
for _ in $(seq 1 45); do
  if port_open "$PORT"; then up=1; break; fi
  kill -0 "$LAUNCH_PID" 2>/dev/null || break
  sleep 1
done
if [[ $up -ne 1 ]]; then
  echo "rosbridge did not come up; last lines of $LOG:" >&2
  tail -30 "$LOG" >&2
  exit 1
fi

echo "== ROS unit tests ($distro)"
(cd "$ROOT/ros2_ws" && timeout 300 "$ROOT/tools/ros.sh" "$distro" pytest -q)

echo "== Swift integration suites"
# Suites opt in via env var so plain `swift test` stays offline.
MRROS_IT_ROSBRIDGE="ws://localhost:$PORT" MRROS_IT_DISTRO="$distro" \
  timeout 900 "$ROOT/tools/ios-test.sh" ROSBridgeClient ARBridgeTransport

echo "integration OK ($distro, $ROBOT)"
