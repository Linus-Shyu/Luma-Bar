#!/usr/bin/env bash
# Build and launch the debug binary, signing it with a stable Apple Development
# identity so macOS Automation (Apple Events) permission survives rebuilds.
# An ad-hoc signature changes its cdhash on every build, so TCC treats each
# build as a brand-new app and the Automation grant can never stick.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build

BIN_DIR="$(swift build --show-bin-path)"
BINARY="$BIN_DIR/LumaBar"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Apple Development:/ { print $2; exit }')"

if [[ -n "$IDENTITY" ]]; then
    # Stable identifier + certificate-chained requirement: the designated
    # requirement no longer depends on binary content, so the Automation
    # grant stays valid across rebuilds.
    codesign --force --sign "$IDENTITY" \
        --identifier com.lumabar.app \
        "$BINARY"
    echo "Signed debug binary with: $IDENTITY"
else
    echo "warning: no Apple Development identity; launching unsigned (Automation grant may not stick)" >&2
fi

exec "$BINARY"
