#!/usr/bin/env bash
# Clone/update the external ROS packages pinned for a distro (tools/external.repos.tsv) into
# ros2_ws/src/external. Works anywhere git does: macOS/RoboStack (tools/ros-build.sh calls this),
# a native Ubuntu ROS install, or CI.
# Usage: tools/fetch-external.sh [humble|jazzy|lyrical]   (default jazzy)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"
EXT="$ROOT/ros2_ws/src/external"
distro="$(mrros_distro "${1:-}")"

mkdir -p "$EXT"
while IFS=$'\t' read -r d name url ref; do
  [[ -z "$d" || "$d" == \#* || "$d" != "$distro" ]] && continue
  if [[ ! -d "$EXT/$name/.git" ]]; then
    git clone -q "$url" "$EXT/$name"
  fi
  git -C "$EXT/$name" fetch -q origin "$ref"
  git -C "$EXT/$name" checkout -q --detach FETCH_HEAD
  echo "external/$name @ $ref ($(git -C "$EXT/$name" rev-parse --short HEAD))"
done < "$ROOT/tools/external.repos.tsv"
