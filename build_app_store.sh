#!/usr/bin/env bash
# Build a sandboxed Mac App Store–oriented .app (local install / archive prep).
# Usage: LUMA_APP_STORE=1 ./build_app_store.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

export LUMA_APP_STORE=1

SECRETS="$ROOT/Sources/LumaBar/BundledAgentSecrets.swift"
SECRETS_EXAMPLE="$ROOT/Support/Templates/BundledAgentSecrets.example.swift"
if [[ ! -f "$SECRETS" && -f "$SECRETS_EXAMPLE" ]]; then
  cp "$SECRETS_EXAMPLE" "$SECRETS"
fi

APP="$ROOT/luma bar.app"
ENTITLEMENTS="$ROOT/Support/LumaBar.AppStore.entitlements"
SIGN_IDENTITY="${LUMA_BAR_CODESIGN_IDENTITY:-}"
ALLOW_ADHOC_SIGN="${LUMA_BAR_ALLOW_ADHOC_SIGN:-1}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Distribution:|3rd Party Mac Developer Application:|Apple Development:|Mac Developer:/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ "$ALLOW_ADHOC_SIGN" == "1" ]]; then
    SIGN_IDENTITY="-"
  else
    echo "error: no code-signing identity for App Store build" >&2
    exit 1
  fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building with LUMA_APP_STORE=1 …"
swift build -c release
cp "$ROOT/.build/release/LumaBar" "$APP/Contents/MacOS/LumaBar"

cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
# Tag Info.plist so we can tell MAS builds apart locally.
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP/Contents/Info.plist" 2>/dev/null \
  || true

if [[ -d "$ROOT/Support/Assets" ]]; then
  cp -R "$ROOT/Support/Assets/." "$APP/Contents/Resources/"
fi
if [[ -d "$ROOT/Support/Fonts" ]]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp -R "$ROOT/Support/Fonts/." "$APP/Contents/Resources/Fonts/"
fi

chmod +x "$APP/Contents/MacOS/LumaBar"
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
find "$APP" -name '*.cstemp' -delete 2>/dev/null || true

echo "Signing (sandbox entitlements) with: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$APP"
else
  /usr/bin/codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "Built MAS-oriented app: $APP"
echo "Next: archive via Xcode with Mac App Store distribution profile, or transporter upload."
