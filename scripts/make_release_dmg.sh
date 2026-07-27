#!/usr/bin/env bash
# Build a distributable DMG. For Gatekeeper-friendly installs you need:
#   1) Developer ID Application certificate
#   2) Apple notary tool credentials
#
# Usage:
#   LUMA_BAR_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   LUMA_BAR_NOTARY_PROFILE="luma-notary" \
#   ./scripts/make_release_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist)"
OUT_DIR="${LUMA_BAR_RELEASE_DIR:-$ROOT/dist}"
APP_NAME="luma bar.app"
DMG_NAME="Luma-Bar-v${VERSION}.dmg"
STAGE="$OUT_DIR/stage"
IDENTITY="${LUMA_BAR_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${LUMA_BAR_NOTARY_PROFILE:-}"

mkdir -p "$OUT_DIR"
rm -rf "$STAGE" "$OUT_DIR/$DMG_NAME" "$OUT_DIR/$APP_NAME"
mkdir -p "$STAGE"

echo "==> Building app"
LUMA_BAR_BUILD_UNIVERSAL="${LUMA_BAR_BUILD_UNIVERSAL:-1}" \
LUMA_BAR_CODESIGN_IDENTITY="${IDENTITY}" \
./build_app.sh

cp -R "$ROOT/$APP_NAME" "$STAGE/$APP_NAME"

# Do NOT ship with a real API key. Strip local secrets file contents if present
# by rebuilding without injection (already the default unless env is set).

if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  echo "==> Codesigning with $IDENTITY"
  /usr/bin/codesign --force --deep --options runtime --sign "$IDENTITY" "$STAGE/$APP_NAME"
else
  echo "WARNING: No Developer ID identity. DMG will likely be blocked by Gatekeeper."
fi

echo "==> Creating DMG"
hdiutil create \
  -volname "Luma Bar" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT_DIR/$DMG_NAME"

if [[ -n "$NOTARY_PROFILE" && -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  echo "==> Submitting for notarization ($NOTARY_PROFILE)"
  xcrun notarytool submit "$OUT_DIR/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT_DIR/$DMG_NAME"
  echo "Notarized: $OUT_DIR/$DMG_NAME"
else
  echo "Skip notarization (set LUMA_BAR_NOTARY_PROFILE to enable)."
  echo "Built: $OUT_DIR/$DMG_NAME (version $VERSION build $BUILD)"
fi

echo "Next: upload $OUT_DIR/$DMG_NAME to Luma-Bar-Download releases."
