#!/usr/bin/env bash
# Format hook: format the file just written/edited.
# Reads the tool payload JSON on stdin; silent no-op for other file types.
set -euo pipefail
file="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"
[[ -z "$file" || ! -f "$file" ]] && exit 0
case "$file" in
  *.swift) command -v swiftformat >/dev/null && swiftformat --quiet "$file" || true ;;
  *.py)    command -v ruff >/dev/null && ruff format --quiet "$file" && ruff check --fix --quiet "$file" || true ;;
esac
exit 0
