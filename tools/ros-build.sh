#!/usr/bin/env bash
# Fetch per-distro external packages and colcon-build ros2_ws into build/<distro>, install/<distro>.
# Usage: tools/ros-build.sh [distro] [extra colcon args]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"
WS="$ROOT/ros2_ws"

distro="$(mrros_distro "${1:-}")"; [[ $# -gt 0 ]] && shift

# 1. external sources at the ref pinned for this distro
"$ROOT/tools/fetch-external.sh" "$distro"

# 2. build inside the env
cd "$WS"
micromamba run -n "ros_$distro" colcon build --symlink-install \
  --build-base "build/$distro" --install-base "install/$distro" \
  --packages-up-to ar_dev_bringup ar_bridge "$@"

echo
echo "built for $distro. Run things with:  tools/ros.sh $distro ros2 ..."
