#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.lumabar.app.keepalive"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$ROOT/luma bar.app"
APP_EXEC="$APP/Contents/MacOS/LumaBar"
RUNNER="$HOME/Library/Application Support/LumaBar/keepalive_runner.sh"
UID_VALUE="$(id -u)"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Application Support/LumaBar"

if [[ ! -x "$APP_EXEC" ]]; then
  echo "App executable not found: $APP_EXEC" >&2
  exit 1
fi

cp "$ROOT/keepalive_runner.sh" "$RUNNER"
chmod +x "$RUNNER"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUNNER</string>
        <string>$APP</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/lumabar.out.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/lumabar.err.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$UID_VALUE" "$PLIST" 2>/dev/null || true
pkill -x LumaBar 2>/dev/null || true
pkill -f "$RUNNER" 2>/dev/null || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
launchctl enable "gui/$UID_VALUE/$LABEL"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

echo "Installed and started $LABEL"
