#!/usr/bin/env bash
# Generate ios/MRRos.xcodeproj (XcodeGen) with your signing settings filled in.
#
#   DEVELOPMENT_TEAM  your Apple team ID (Xcode > Settings > Accounts > your team; 10 characters).
#                     Empty is fine for simulator builds and package tests.
#   MRROS_BUNDLE_ID   the app's bundle identifier. It must be unique to your team, so set your own
#                     (e.g. io.github.<you>.mrros). Default: io.github.louridoc.mrros.
#
# Either export them, or put KEY=value lines in ~/.mrros/config (read here, not executed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

config_value() {  # config_value KEY: value from ~/.mrros/config, if any
  local file="$HOME/.mrros/config"
  [[ -f "$file" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$file" | tail -1 | tr -d '"'"'"
}

export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(config_value DEVELOPMENT_TEAM)}"
export MRROS_BUNDLE_ID="${MRROS_BUNDLE_ID:-$(config_value MRROS_BUNDLE_ID)}"
export MRROS_BUNDLE_ID="${MRROS_BUNDLE_ID:-io.github.louridoc.mrros}"

cd "$ROOT/ios"
xcodegen generate --quiet
echo "generated ios/MRRos.xcodeproj (bundle id $MRROS_BUNDLE_ID, team ${DEVELOPMENT_TEAM:-none: simulator only})"
