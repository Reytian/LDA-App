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
MODEL_PATH="${MODEL_PATH:-$HOME/Developer/lda-models/lda-v2-Q4_K_M.gguf}"

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
BIN="$(swift build -c release --product LDAApp "${SCRATCH[@]}" --show-bin-path)/LDAApp"

# Ship gate: the test seams are #if DEBUG, so a release binary must contain
# ZERO *ForTesting symbols. The unit suite cannot catch a regression here
# because it always builds debug; this scan is the only check that does.
echo "==> Verifying no test seams in the release binary"
if nm "$BIN" 2>/dev/null | grep -qi "ForTesting"; then
  echo "!! Release binary contains test-seam symbols; refusing to package." >&2
  nm "$BIN" | grep -i "ForTesting" | head -5 >&2
  exit 1
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
