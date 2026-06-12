#!/bin/bash
#
# Build LDA.app as a distributable macOS bundle, optionally code-signed and
# notarized. The unsigned bundle is always produced (runnable locally). Signing
# and notarization happen only when the matching environment variables are set.
#
# Always builds:
#   - Release LDAApp binary via SwiftPM
#   - LDA.app bundle (Info.plist + the static-linked binary + bundled GGUF model)
#
# Optional (set to enable):
#   CODESIGN_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     a notarytool keychain profile name created with:
#                        xcrun notarytool store-credentials NOTARY_PROFILE \
#                          --apple-id you@example.com --team-id TEAMID \
#                          --password APP_SPECIFIC_PASSWORD
#   MODEL_PATH         path to the GGUF to bundle (default ~/Developer/lda-models/lda-v2-Q4_K_M.gguf)
#
# House rules: English only. No em-dash or en-dash-as-separator.
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$PKG/dist"
APP="$DIST/LDA.app"
MODEL_PATH="${MODEL_PATH:-$HOME/Developer/lda-models/lda-v2-Q4_K_M.gguf}"

echo "==> Building release binary"
cd "$PKG"
swift build -c release --product LDAApp >/dev/null
BIN="$(swift build -c release --product LDAApp --show-bin-path)/LDAApp"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/LDAApp"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$PKG/packaging/AppIcon.icns" ]; then
  cp "$PKG/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

if [ -f "$MODEL_PATH" ]; then
  echo "==> Bundling model ($(du -h "$MODEL_PATH" | cut -f1))"
  cp "$MODEL_PATH" "$APP/Contents/Resources/lda-v2-Q4_K_M.gguf"
else
  echo "!! Model not found at $MODEL_PATH; bundling without it (app runs deterministic-only)."
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Code signing with hardened runtime"
  # Sign the executable first, then the bundle, with the offline entitlements.
  codesign --force --options runtime --timestamp \
    --entitlements "$PKG/packaging/LDA.entitlements" \
    --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/LDAApp"
  codesign --force --options runtime --timestamp \
    --entitlements "$PKG/packaging/LDA.entitlements" \
    --sign "$CODESIGN_IDENTITY" "$APP"
  echo "==> Verifying signature"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "!! CODESIGN_IDENTITY not set; produced an UNSIGNED bundle (open with right-click > Open)."
fi

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Notarizing"
  ZIP="$DIST/LDA.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
else
  echo "!! NOTARY_PROFILE not set (or unsigned); skipping notarization."
fi

echo "==> Done: $APP"
