#!/usr/bin/env bash
# Run a command inside a distro's env with the built workspace sourced (if built).
# Usage: tools/ros.sh <distro> <command...>
#   tools/ros.sh jazzy ros2 topic list
#   tools/ros.sh humble ros2 launch ar_dev_bringup dev.launch.py robot:=ur30
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"

distro="$(mrros_distro "${1:?distro required}")"; shift
[[ $# -gt 0 ]] || { echo "usage: $0 <distro> <command...>" >&2; exit 2; }

setup="$ROOT/ros2_ws/install/$distro/setup.bash"
if [[ -f "$setup" ]]; then
  exec micromamba run -n "ros_$distro" bash -c 'source "$0" && exec "$@"' "$setup" "$@"
else
  exec micromamba run -n "ros_$distro" "$@"
fi
