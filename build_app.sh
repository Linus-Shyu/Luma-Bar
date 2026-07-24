#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/luma bar.app"
SIGN_IDENTITY="${LUMA_BAR_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:|Developer ID Application:|Mac Developer:/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/LumaBar" "$APP/Contents/MacOS/LumaBar"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$ROOT/Support/Assets" ]]; then
  cp -R "$ROOT/Support/Assets/." "$APP/Contents/Resources/"
fi
chmod +x "$APP/Contents/MacOS/LumaBar"
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Signing with: $SIGN_IDENTITY"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "$APP"
