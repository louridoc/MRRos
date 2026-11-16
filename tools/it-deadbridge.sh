#!/usr/bin/env bash
# Liveness integration test: start a websocket server that plays dead and check the client's
# heartbeat detects it. Usage: tools/it-deadbridge.sh [distro]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"
distro="$(mrros_distro "${1:-}")"
PORT=9099
LOG="$ROOT/ros2_ws/log/dead_bridge.log"; mkdir -p "$(dirname "$LOG")"

"$ROOT/tools/ros.sh" "$distro" python "$ROOT/tools/fake_dead_bridge.py" "$PORT" > "$LOG" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
  sleep 0.5
done

cd "$ROOT/ios/Packages/ROSBridgeClient"
MRROS_IT_DEADBRIDGE="ws://127.0.0.1:$PORT" timeout 120 swift test --filter DeadServerTests 2>&1 \
  | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "DEADBRIDGE|✘|✔ Test|error:|Issue"
