#!/usr/bin/env bash
# CI / local: build → Developer ID sign → notarize → staple → zip (+ optional DMG).
#
# Required env (CI):
#   LUMA_BAR_CODESIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)"
#
# Notary auth — either Apple ID *or* App Store Connect API key:
#   APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID
#   APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER
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

# Prefer Apple ID auth when present (works around ASC API key 401s).
notary_auth_args() {
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo "==> notarytool auth: Apple ID ($APPLE_ID, team=$APPLE_TEAM_ID)" >&2
    printf '%s\n' --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
    return 0
  fi
  if [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
    [[ -f "$APPLE_API_KEY_PATH" ]] || die "API key file not found: $APPLE_API_KEY_PATH"
    if ! head -n 1 "$APPLE_API_KEY_PATH" | grep -q "BEGIN PRIVATE KEY"; then
      die "APPLE_API_KEY_BASE64 does not decode to a .p8 private key (missing BEGIN PRIVATE KEY header)"
    fi
    echo "==> notarytool auth: API key (key-id=$APPLE_API_KEY_ID)" >&2
    printf '%s\n' --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
    return 0
  fi
  die "set Apple ID auth (APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID) or API key auth (APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER)"
}

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
if command -v spctl >/dev/null 2>&1; then
  spctl --assess --type execute -vv "$STAGE/$APP_NAME" 2>&1 || true
else
  echo "note: spctl not available on this runner; skipping Gatekeeper assess"
fi

cp -R "$STAGE/$APP_NAME" "$SIGNED_APP"

echo "==> Zip for notarization (Apple requires zip/dmg/pkg, not raw .app)"
/usr/bin/ditto -c -k --keepParent "$SIGNED_APP" "$OUT_DIR/$ZIP_NAME"

if [[ "${LUMA_BAR_SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> Skipping notarization (LUMA_BAR_SKIP_NOTARIZE=1)"
else
  # Capture auth flags into an array (handles spaces in values safely).
  AUTH_ARGS=()
  while IFS= read -r line; do
    AUTH_ARGS+=("$line")
  done < <(notary_auth_args)

  echo "==> Submit to notarytool"
  if ! xcrun notarytool submit "$OUT_DIR/$ZIP_NAME" "${AUTH_ARGS[@]}" --wait; then
    echo "error: notarytool failed." >&2
    if [[ -n "${APPLE_ID:-}" ]]; then
      echo "Apple ID auth 401 → check APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD (appleid.apple.com), APPLE_TEAM_ID." >&2
    else
      echo "API key 401 → Key ID / Issuer / .p8 rejected by Apple (even when ASC UI looks correct)." >&2
      echo "Fallback: set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID secrets." >&2
    fi
    exit 1
  fi

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
    xcrun notarytool submit "$OUT_DIR/$DMG_NAME" "${AUTH_ARGS[@]}" --wait
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
