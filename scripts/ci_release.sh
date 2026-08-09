#!/usr/bin/env bash
# CI / local: build → Developer ID sign → notarize → staple → zip (+ optional DMG).
#
# Required env (CI):
#   LUMA_BAR_CODESIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)"
#   APPLE_API_KEY_PATH           path to AuthKey_XXX.p8
#   APPLE_API_KEY_ID
#   APPLE_API_ISSUER             UUID issuer
#
# Optional:
#   LUMA_BAR_BUILD_UNIVERSAL=1
#   LUMA_BAR_RELEASE_DIR=dist
#   LUMA_BAR_SKIP_NOTARIZE=1
#   LUMA_BAR_MAKE_DMG=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }
need() { [[ -n "${!1:-}" ]] || die "missing env $1"; }

APP_NAME="luma bar.app"
OUT_DIR="${LUMA_BAR_RELEASE_DIR:-$ROOT/dist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist 2>/dev/null || echo "0.0.0")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist 2>/dev/null || echo "0")"
TAG_NAME="${LUMA_BAR_RELEASE_TAG:-}"
ZIP_NAME="Luma-Bar-v${VERSION}.zip"
DMG_NAME="Luma-Bar-v${VERSION}.dmg"
STAGE="$OUT_DIR/stage"
SIGNED_APP="$OUT_DIR/$APP_NAME"

need LUMA_BAR_CODESIGN_IDENTITY
IDENTITY="$LUMA_BAR_CODESIGN_IDENTITY"
[[ "$IDENTITY" != "-" ]] || die "ad-hoc signing is not allowed for notarized releases"

mkdir -p "$OUT_DIR"
rm -rf "$STAGE" "$SIGNED_APP" "$OUT_DIR/$ZIP_NAME" "$OUT_DIR/$DMG_NAME"
mkdir -p "$STAGE"

echo "==> Building universal .app (Developer ID)"
LUMA_BAR_BUILD_UNIVERSAL="${LUMA_BAR_BUILD_UNIVERSAL:-1}" \
LUMA_BAR_CODESIGN_IDENTITY="$IDENTITY" \
LUMA_BAR_ALLOW_ADHOC_SIGN=0 \
  ./build_app.sh

[[ -d "$ROOT/$APP_NAME" ]] || die "build_app.sh did not produce $APP_NAME"
cp -R "$ROOT/$APP_NAME" "$STAGE/$APP_NAME"

echo "==> Re-sign with hardened runtime + entitlements"
ENTITLEMENTS="$ROOT/Support/LumaBar.entitlements"
/usr/bin/codesign \
  --force --deep --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$STAGE/$APP_NAME"

echo "==> Verify signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGE/$APP_NAME"
/usr/bin/spctl --assess --type execute -vv "$STAGE/$APP_NAME" 2>&1 || true

cp -R "$STAGE/$APP_NAME" "$SIGNED_APP"

echo "==> Zip for notarization (Apple requires zip/dmg/pkg, not raw .app)"
/usr/bin/ditto -c -k --keepParent "$SIGNED_APP" "$OUT_DIR/$ZIP_NAME"

if [[ "${LUMA_BAR_SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> Skipping notarization (LUMA_BAR_SKIP_NOTARIZE=1)"
else
  need APPLE_API_KEY_PATH
  need APPLE_API_KEY_ID
  need APPLE_API_ISSUER
  [[ -f "$APPLE_API_KEY_PATH" ]] || die "API key file not found: $APPLE_API_KEY_PATH"

  echo "==> Submit to notarytool"
  xcrun notarytool submit "$OUT_DIR/$ZIP_NAME" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait

  echo "==> Staple ticket onto .app"
  xcrun stapler staple "$SIGNED_APP"
  xcrun stapler validate "$SIGNED_APP"

  # Refresh zip so the stapled ticket is inside the artifact users download.
  rm -f "$OUT_DIR/$ZIP_NAME"
  /usr/bin/ditto -c -k --keepParent "$SIGNED_APP" "$OUT_DIR/$ZIP_NAME"

  if [[ "${LUMA_BAR_MAKE_DMG:-0}" == "1" ]]; then
    echo "==> Create + notarize DMG"
    hdiutil create \
      -volname "Luma Bar" \
      -srcfolder "$STAGE" \
      -ov -format UDZO \
      "$OUT_DIR/$DMG_NAME"
    xcrun notarytool submit "$OUT_DIR/$DMG_NAME" \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER" \
      --wait
    xcrun stapler staple "$OUT_DIR/$DMG_NAME"
    xcrun stapler validate "$OUT_DIR/$DMG_NAME"
  fi
fi

{
  echo "version=$VERSION"
  echo "build=$BUILD"
  echo "tag=${TAG_NAME:-none}"
  echo "app=$SIGNED_APP"
  echo "zip=$OUT_DIR/$ZIP_NAME"
  [[ -f "$OUT_DIR/$DMG_NAME" ]] && echo "dmg=$OUT_DIR/$DMG_NAME"
} | tee "$OUT_DIR/release-meta.txt"

echo "==> Done"
