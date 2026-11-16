#!/usr/bin/env bash
# Shared shell settings for tools/*.sh. Sourced, not executed.

export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"
export MRROS_DEFAULT_DISTRO="${MRROS_DEFAULT_DISTRO:-jazzy}"
MRROS_DISTROS=(humble jazzy lyrical)

# Validate a distro name; empty → default. Prints the distro.
mrros_distro() {
  local d="${1:-$MRROS_DEFAULT_DISTRO}"
  for ok in "${MRROS_DISTROS[@]}"; do
    [[ "$d" == "$ok" ]] && { echo "$d"; return 0; }
  done
  echo "unknown ROS distro '$d' (expected: ${MRROS_DISTROS[*]})" >&2
  return 2
}
