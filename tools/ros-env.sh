#!/usr/bin/env bash
# Manage RoboStack micromamba environments, one per ROS distro (ros_humble, ros_jazzy, ros_lyrical).
# Usage:
#   tools/ros-env.sh create [distro]          # default jazzy
#   tools/ros-env.sh update [distro]
#   tools/ros-env.sh add <distro> <pkg...>    # e.g. add jazzy moveit  → ros-jazzy-moveit
#   tools/ros-env.sh list
#   tools/ros-env.sh shell-hint
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"
TEMPLATE="$ROOT/tools/ros_env.template.yaml"

command -v micromamba >/dev/null || { echo "micromamba not found (brew install micromamba)" >&2; exit 1; }

render() {
  local distro="$1" out
  out="$(mktemp -t ros_env_"$distro".XXXX).yaml"
  sed "s/{{DISTRO}}/$distro/g" "$TEMPLATE" > "$out"
  echo "$out"
}

cmd="${1:-}"
case "$cmd" in
  create|update)
    distro="$(mrros_distro "${2:-}")"
    f="$(render "$distro")"
    if [[ "$cmd" == create ]]; then
      micromamba create -y -n "ros_$distro" -f "$f"
    else
      micromamba install -y -n "ros_$distro" -f "$f"
    fi
    echo "env ros_$distro ready. Use: tools/ros.sh $distro <command>   (or micromamba activate ros_$distro)"
    ;;
  add)
    distro="$(mrros_distro "${2:?distro required}")"; shift 2
    pkgs=(); for p in "$@"; do pkgs+=("ros-$distro-$p"); done
    micromamba install -y -n "ros_$distro" -c "robostack-$distro" -c conda-forge "${pkgs[@]}"
    ;;
  list)
    micromamba env list
    ;;
  shell-hint)
    cat <<EOF
Environments live under MAMBA_ROOT_PREFIX=$MAMBA_ROOT_PREFIX
For interactive use add to ~/.zshrc:
  export MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX"
  eval "\$(micromamba shell hook --shell zsh)"
then: micromamba activate ros_jazzy
EOF
    ;;
  *)
    sed -n '2,8p' "$0" >&2
    exit 2
    ;;
esac
