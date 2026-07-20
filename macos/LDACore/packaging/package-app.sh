#!/bin/bash
#
# Build LDA.app as a distributable macOS bundle, optionally code-signed and
# notarized. Every bundle is signed so the App Sandbox and offline entitlements
# are active. Local builds use an ad hoc signature; distribution builds use the
# Developer ID identity supplied by the caller.
#
# Always builds:
#   - Release LDAApp binary via SwiftPM
#   - LDA.app bundle (Info.plist + the static-linked binary + bundled GGUF model)
#
# Optional (set to enable):
#   CODESIGN_IDENTITY  optional Developer ID identity for distribution, e.g.
#                      "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     a notarytool keychain profile name created with:
#                        xcrun notarytool store-credentials NOTARY_PROFILE \
#                          --apple-id you@example.com --team-id TEAMID \
#                          --password APP_SPECIFIC_PASSWORD
#   MODEL_PATH         path to the GGUF to bundle (default ~/Developer/lda-models/lda-v2-Q4_K_M.gguf)
#   SCRATCH_PATH       SwiftPM scratch directory. Set it OUTSIDE iCloud when the
#                      checkout lives in an iCloud-synced folder, or the build
#                      can fail with "input file was modified during the build".
#   STAGE_SOURCE       copy package inputs to a temp dir before building
#                      (default 1). This avoids iCloud source timestamp races.
#   KEEP_STAGE         keep the temp source copy for debugging (default 0).
#
# House rules: English only. No em-dash or en-dash-as-separator.
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PKG="$PKG"
STAGE_DIR=""
# DIST_PATH overrides where LDA.app is written. It MUST be outside iCloud because
# every build is signed. iCloud continuously stamps com.apple.FinderInfo /
# com.apple.fileprovider / com.apple.provenance xattrs on every bundle file
# (faster than a one-time strip and re-stamped mid-sign), which makes codesign
# fail with "resource fork, Finder information, or similar detritus not
# allowed". An iCloud checkout therefore defaults to ~/Developer/lda-dist;
# other checkouts default to the package-local dist directory.
DEFAULT_DIST="$PKG/dist"
case "$PKG" in
  *"/Mobile Documents/"*|*"/Documents/"*) DEFAULT_DIST="$HOME/Developer/lda-dist" ;;
esac
DIST="${DIST_PATH:-$DEFAULT_DIST}"
APP="$DIST/LDA.app"
MODEL_PATH="${MODEL_PATH:-$HOME/Developer/lda-models/lda-v2-Q4_K_M.gguf}"

case "$DIST" in
*"/Mobile Documents/"*|*"/Documents/"*)
  echo "!! Refusing to sign inside an iCloud-synced path ($DIST)."
  echo "!! Set DIST_PATH to a non-iCloud location, e.g. DIST_PATH=~/Developer/lda-dist"
  exit 1
  ;;
esac

cleanup() {
  if [ -n "$STAGE_DIR" ] && [ "${KEEP_STAGE:-0}" != "1" ]; then
    rm -rf "$STAGE_DIR"
  fi
}
trap cleanup EXIT

if [ "${STAGE_SOURCE:-1}" != "0" ]; then
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lda-source-stage.XXXXXX")"
  BUILD_PKG="$STAGE_DIR/LDACore"
  mkdir -p "$BUILD_PKG"
  echo "==> Staging source outside iCloud"
  for item in Package.swift Package.resolved Sources Tests Frameworks packaging; do
    if [ -e "$PKG/$item" ]; then
      cp -R "$PKG/$item" "$BUILD_PKG/"
    fi
  done
fi

echo "==> Building release binary"
cd "$BUILD_PKG"
if [ -n "${SCRATCH_PATH:-}" ]; then
  swift build -c release --product LDAApp --scratch-path "$SCRATCH_PATH" >/dev/null
  BIN="$(swift build -c release --product LDAApp --scratch-path "$SCRATCH_PATH" --show-bin-path)/LDAApp"
else
  swift build -c release --product LDAApp >/dev/null
  BIN="$(swift build -c release --product LDAApp --show-bin-path)/LDAApp"
fi

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

# Strip extended attributes first. macOS stamps files with xattrs such as
# com.apple.provenance (on execution) and com.apple.quarantine / iCloud
# sync metadata (on the copied 2.5 GB model), and codesign refuses any file
# carrying a "resource fork, Finder information, or similar detritus".
xattr -cr "$APP"

SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
TIMESTAMP_ARGS=(--timestamp=none)
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Developer ID signing with hardened runtime"
  TIMESTAMP_ARGS=(--timestamp)
else
  echo "==> Ad hoc signing for local use with App Sandbox enabled"
fi

# Sign the executable first, then the bundle, with the offline entitlements.
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  --entitlements "$PKG/packaging/LDA.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/LDAApp"
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  --entitlements "$PKG/packaging/LDA.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"
echo "==> Verifying signature and sandbox entitlements"
codesign --verify --strict --verbose=2 "$APP"

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
  echo "!! NOTARY_PROFILE not set (or no Developer ID identity); skipping notarization."
fi

echo "==> Done: $APP"
