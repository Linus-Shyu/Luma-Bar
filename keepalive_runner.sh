#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/luma bar.app}"
PROCESS_NAME="LumaBar"

while true; do
  if ! pgrep -x "$PROCESS_NAME" >/dev/null; then
    /usr/bin/open -g -n "$APP" >/dev/null 2>&1 || true
  fi

  sleep 3
done
