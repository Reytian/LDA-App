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
#   MODEL_PATH         Quick model GGUF to bundle (default ~/Developer/lda-models/Qwen3.5-4B-Q4_K_M.gguf)
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
# DIST_PATH overrides where LDA.app is written. It MUST be outside iCloud when
# signing: iCloud continuously stamps com.apple.FinderInfo /
# com.apple.fileprovider / com.apple.provenance xattrs on every bundle file
# (faster than a one-time strip and re-stamped mid-sign), which makes codesign
# fail with "resource fork, Finder information, or similar detritus not
# allowed". Defaults to $PKG/dist, fine for unsigned local builds.
DIST="${DIST_PATH:-$PKG/dist}"
APP="$DIST/LDA.app"
# Quick (Qwen3.5-4B) is the ONLY bundled model. It peaks at 3.1 GB so it runs
# on the 16 GB minimum spec, which means an offline user always has a model
# that works. Balanced needs 24 GB and is downloaded through Manage Models.
MODEL_PATH="${MODEL_PATH:-$HOME/Developer/lda-models/Qwen3.5-4B-Q4_K_M.gguf}"

if [ -n "${CODESIGN_IDENTITY:-}" ] && printf '%s' "$DIST" | grep -qi "/Mobile Documents/\|/Documents/"; then
  echo "!! Refusing to sign inside an iCloud-synced path ($DIST)."
  echo "!! Set DIST_PATH to a non-iCloud location, e.g. DIST_PATH=~/Developer/lda-dist"
  exit 1
fi

cleanup() {
  if [ -n "$STAGE_DIR" ] && [ "${KEEP_STAGE:-0}" != "1" ]; then
    rm -rf "$STAGE_DIR"
  fi
}
trap cleanup EXIT

SCRATCH=()
if [ -n "${SCRATCH_PATH:-}" ]; then
  SCRATCH=(--scratch-path "$SCRATCH_PATH")
fi

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
swift build -c release --product LDAApp "${SCRATCH[@]}" >/dev/null
BUILD_DIR="$(swift build -c release --product LDAApp "${SCRATCH[@]}" --show-bin-path)"
BIN="$BUILD_DIR/LDAApp"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/LDAApp"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$PKG/packaging/AppIcon.icns" ]; then
  cp "$PKG/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM resource bundles. LDAUI reads Models.json (the tier manifest) during
# startup, and the generated accessor looks in the .app ROOT, not
# Contents/Resources. Without this the packaged app has an empty catalog: the
# ladder collapses to Patterns only and Manage Models shows nothing.
echo "==> Bundling SwiftPM resource bundles"
FOUND_BUNDLE=0
for RB in "$BUILD_DIR"/*.bundle; do
  [ -e "$RB" ] || continue
  echo "    $(basename "$RB")"
  cp -R "$RB" "$APP/"
  FOUND_BUNDLE=1
done
if [ "$FOUND_BUNDLE" -eq 0 ] || [ ! -f "$APP/LDACore_LDAUI.bundle/Models.json" ]; then
  echo "!! LDACore_LDAUI.bundle/Models.json is missing from $BUILD_DIR."
  echo "!! Refusing to ship a build whose model catalog would be empty."
  exit 1
fi

if [ -f "$MODEL_PATH" ]; then
  echo "==> Bundling Quick model ($(du -h "$MODEL_PATH" | cut -f1))"
  cp "$MODEL_PATH" "$APP/Contents/Resources/$(basename "$MODEL_PATH")"
else
  echo "!! Quick model not found at $MODEL_PATH."
  echo "!! Shipping without it leaves a fresh install with no working model."
  exit 1
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Code signing with hardened runtime"
  # Strip extended attributes first. macOS stamps files with xattrs such as
  # com.apple.provenance (on execution) and com.apple.quarantine / iCloud
  # sync metadata (on the copied 2.5 GB model), and codesign refuses any file
  # carrying a "resource fork, Finder information, or similar detritus".
  xattr -cr "$APP"
  # Sign the executable first, then the bundle, with the offline entitlements.
  codesign --force --options runtime --timestamp \
    --entitlements "$PKG/packaging/LDA.entitlements" \
    --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/LDAApp"
  codesign --force --options runtime --timestamp \
    --entitlements "$PKG/packaging/LDA.entitlements" \
    --sign "$CODESIGN_IDENTITY" "$APP"
  echo "==> Verifying signature"
  codesign --verify --strict --verbose=2 "$APP"
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
