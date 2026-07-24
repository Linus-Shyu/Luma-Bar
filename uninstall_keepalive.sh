#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lumabar.app.keepalive"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

launchctl bootout "gui/$UID_VALUE" "$PLIST" 2>/dev/null || true
launchctl disable "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
pkill -x LumaBar 2>/dev/null || true
pkill -f "$HOME/Library/Application Support/LumaBar/keepalive_runner.sh" 2>/dev/null || true

echo "Stopped $LABEL"
