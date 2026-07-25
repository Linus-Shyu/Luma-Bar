#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="$ROOT/luma bar.app"
SIGN_IDENTITY="${LUMA_BAR_CODESIGN_IDENTITY:-}"
BUILD_UNIVERSAL="${LUMA_BAR_BUILD_UNIVERSAL:-1}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:|Mac Developer:/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
  ARM64_TRIPLE="arm64-apple-macosx14.0"
  X86_64_TRIPLE="x86_64-apple-macosx14.0"
  swift build -c release --triple "$ARM64_TRIPLE"
  swift build -c release --triple "$X86_64_TRIPLE"
  ARM64_BIN="$(swift build -c release --triple "$ARM64_TRIPLE" --show-bin-path)/LumaBar"
  X86_64_BIN="$(swift build -c release --triple "$X86_64_TRIPLE" --show-bin-path)/LumaBar"
  /usr/bin/lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$APP/Contents/MacOS/LumaBar"
else
  swift build -c release
  cp "$ROOT/.build/release/LumaBar" "$APP/Contents/MacOS/LumaBar"
fi

cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$ROOT/Support/Assets" ]]; then
  cp -R "$ROOT/Support/Assets/." "$APP/Contents/Resources/"
fi
chmod +x "$APP/Contents/MacOS/LumaBar"
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Signing with: $SIGN_IDENTITY"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "$APP"
