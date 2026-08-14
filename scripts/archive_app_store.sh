#!/usr/bin/env bash
# Archive the Mac App Store target and optionally upload to App Store Connect.
# Usage:
#   ./scripts/archive_app_store.sh           # archive only
#   ./scripts/archive_app_store.sh --upload  # archive + Transporter upload
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHIVE_PATH="${LUMA_BAR_ARCHIVE_PATH:-$ROOT/dist/LumaBar.xcarchive}"
EXPORT_PATH="${LUMA_BAR_EXPORT_PATH:-$ROOT/dist/mas}"
SCHEME="luma bar"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"

echo "==> Archiving Mac App Store build (LUMA_APP_STORE via Xcode settings)"
xcodebuild \
  -project "$ROOT/LumaBar.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "==> Archive ready: $ARCHIVE_PATH"
echo "    Open Xcode → Organizer → Distribute App → App Store Connect"
echo "    or re-run with --upload to export via Support/exportOptions-appstore.plist"

if [[ "${1:-}" == "--upload" ]]; then
  echo "==> Exporting / uploading to App Store Connect"
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$ROOT/Support/exportOptions-appstore.plist"
  echo "==> Export finished: $EXPORT_PATH"
fi
