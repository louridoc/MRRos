#!/usr/bin/env bash
# Run `swift test` for every local package on macOS (fast, no simulator).
# Usage: tools/ios-test.sh [PackageName ...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKGS_DIR="$ROOT/ios/Packages"

if [[ $# -gt 0 ]]; then
  pkgs=("$@")
else
  pkgs=()
  for d in "$PKGS_DIR"/*/; do pkgs+=("$(basename "$d")"); done
fi

failed=()
for p in "${pkgs[@]}"; do
  echo "=== $p"
  if ! (cd "$PKGS_DIR/$p" && swift test --quiet 2>&1 | tail -20); then
    failed+=("$p")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "all packages green: ${pkgs[*]}"
