#!/usr/bin/env bash
# Format one file in place: `tools/hooks/format.sh <file>`. Also usable as an editor/save hook
# that passes {"tool_input": {"file_path": ...}} JSON on stdin. No-op for other file types.
set -euo pipefail
if [[ $# -ge 1 ]]; then
  file="$1"
else
  file="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"
fi
[[ -z "$file" || ! -f "$file" ]] && exit 0
case "$file" in
  *.swift) command -v swiftformat >/dev/null && swiftformat --quiet "$file" || true ;;
  *.py)    command -v ruff >/dev/null && ruff format --quiet "$file" && ruff check --fix --quiet "$file" || true ;;
esac
exit 0
