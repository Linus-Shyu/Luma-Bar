#!/usr/bin/env bash
# Build + install a stable-signed copy to ~/Applications so TCC permissions persist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INSTALL_DIR="${LUMA_BAR_INSTALL_DIR:-$HOME/Applications}"
APP_NAME="luma bar.app"
DEST="$INSTALL_DIR/$APP_NAME"

mkdir -p "$INSTALL_DIR"

echo "==> Building (arm64, Developer ID)"
LUMA_BAR_BUILD_UNIVERSAL="${LUMA_BAR_BUILD_UNIVERSAL:-0}" \
LUMA_BAR_ALLOW_ADHOC_SIGN="${LUMA_BAR_ALLOW_ADHOC_SIGN:-0}" \
./build_app.sh

echo "==> Installing to $DEST"
pkill -x LumaBar 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
cp -R "$ROOT/$APP_NAME" "$DEST"
/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Signature"
codesign -dv --verbose=2 "$DEST" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|flags' || true

echo "==> Launching"
open "$DEST"

# Open the privacy panes users usually need once.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
sleep 0.4
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true

cat <<EOF

Installed: $DEST

请在系统设置里勾选「luma bar」（同一份签名以后重建不用再勾）：
  1. 隐私与安全性 → 辅助功能
  2. 隐私与安全性 → 屏幕录制
  3. 如 Agent 需要：自动化 / 完全磁盘访问权限

以后请只从「应用程序」打开这份，不要用桌面工程目录里临时的 .app。
EOF
