#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SECRETS="$ROOT/Sources/LumaBar/BundledAgentSecrets.swift"
SECRETS_EXAMPLE="$ROOT/Support/Templates/BundledAgentSecrets.example.swift"
if [[ ! -f "$SECRETS" && -f "$SECRETS_EXAMPLE" ]]; then
  cp "$SECRETS_EXAMPLE" "$SECRETS"
fi
# Prefer build-time env injection for distribution without editing source.
if [[ -n "${LUMA_BAR_DEEPSEEK_API_KEY:-}" ]]; then
  python3 - "$SECRETS" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
key = __import__("os").environ.get("LUMA_BAR_DEEPSEEK_API_KEY", "").replace("\\", "\\\\").replace("\"", "\\\"")
text, n = re.subn(
    r'static let deepSeekAPIKey = ".*"',
    f'static let deepSeekAPIKey = "{key}"',
    text,
    count=1,
)
if n != 1:
    raise SystemExit("failed to inject LUMA_BAR_DEEPSEEK_API_KEY into BundledAgentSecrets.swift")
path.write_text(text)
print("Injected LUMA_BAR_DEEPSEEK_API_KEY into BundledAgentSecrets.swift")
PY
fi

APP="$ROOT/luma bar.app"
SIGN_IDENTITY="${LUMA_BAR_CODESIGN_IDENTITY:-}"
BUILD_UNIVERSAL="${LUMA_BAR_BUILD_UNIVERSAL:-1}"
# Ad-hoc (`-`) changes CDHash every build → macOS asks for Accessibility / Screen
# Recording again. Prefer a stable Developer ID so TCC grants stick.
ALLOW_ADHOC_SIGN="${LUMA_BAR_ALLOW_ADHOC_SIGN:-0}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:|Mac Developer:/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ "$ALLOW_ADHOC_SIGN" == "1" ]]; then
    SIGN_IDENTITY="-"
  else
    echo "error: no Apple code-signing identity found." >&2
    echo "Install a Developer ID Application certificate, or set LUMA_BAR_ALLOW_ADHOC_SIGN=1 (permissions will reset each build)." >&2
    exit 1
  fi
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
if [[ -d "$ROOT/Support/zh-Hans.lproj" ]]; then
  mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
  cp -R "$ROOT/Support/zh-Hans.lproj/." "$APP/Contents/Resources/zh-Hans.lproj/"
fi

# SPM String Catalog resource bundle (LumaBar_LumaBar.bundle)
copy_spm_resource_bundle() {
  local bin_dir="$1"
  local bundle
  for bundle in "$bin_dir"/LumaBar_LumaBar.bundle "$bin_dir"/LumaBar.bundle; do
    if [[ -d "$bundle" ]]; then
      rm -rf "$APP/Contents/Resources/$(basename "$bundle")"
      cp -R "$bundle" "$APP/Contents/Resources/"
      # Also keep a copy next to the executable for Bundle.module lookup.
      rm -rf "$APP/Contents/MacOS/$(basename "$bundle")"
      cp -R "$bundle" "$APP/Contents/MacOS/"
      echo "Bundled localization: $(basename "$bundle")"
      return 0
    fi
  done
  echo "warning: SPM resource bundle not found under $bin_dir" >&2
  return 1
}

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
  copy_spm_resource_bundle "$(swift build -c release --triple "$ARM64_TRIPLE" --show-bin-path)" || true
else
  copy_spm_resource_bundle "$(swift build -c release --show-bin-path)" || true
fi

if [[ -d "$ROOT/Support/Assets" ]]; then
  cp -R "$ROOT/Support/Assets/." "$APP/Contents/Resources/"
fi
if [[ -d "$ROOT/Support/Fonts" ]]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp -R "$ROOT/Support/Fonts/." "$APP/Contents/Resources/Fonts/"
fi
chmod +x "$APP/Contents/MacOS/LumaBar"
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# Drop interrupted codesign leftovers that break subsequent signs.
find "$APP" -name '*.cstemp' -delete 2>/dev/null || true
echo "Signing with: $SIGN_IDENTITY"
ENTITLEMENTS="$ROOT/Support/LumaBar.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
elif [[ -f "$ENTITLEMENTS" ]]; then
  # Hardened runtime + audio-input entitlement so macOS can prompt for Microphone.
  /usr/bin/codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
else
  /usr/bin/codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi

echo "$APP"
