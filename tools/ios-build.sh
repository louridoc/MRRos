#!/usr/bin/env bash
# Regenerate the Xcode project and build the app for the iOS simulator.
# Usage: tools/ios-build.sh [simulator-name]
#   no arg  → generic simulator destination (build-only check, no booted device needed)
#   name    → e.g. "iPhone 17 Pro" (use with XcodeBuildMCP / run on a specific sim)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  DEST="platform=iOS Simulator,name=$1"
else
  DEST="generic/platform=iOS Simulator"
fi

cd "$ROOT/ios"
xcodegen generate --quiet
LOG="$(mktemp -t mrros_build).log"
set +e
xcodebuild -project MRRos.xcodeproj -scheme MRRos -destination "$DEST" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1
status=$?
set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$LOG" || true
[[ $status -eq 0 ]] || { echo "full log: $LOG" >&2; exit $status; }
