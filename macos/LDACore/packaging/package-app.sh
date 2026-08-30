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
# Quick (Qwen3.5-4B) is the ONLY bundled model. It peaks at 3.1 GB so it runs
# on the 16 GB minimum spec, which means an offline user always has a model
# that works. Balanced needs 24 GB and is downloaded through Manage Models.
MODEL_PATH="${MODEL_PATH:-$HOME/Developer/lda-models/Qwen3.5-4B-Q4_K_M.gguf}"

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
# Their explicit SCRATCH_PATH branching is kept: the SCRATCH array this used to
# expand no longer exists, so the old form would break under set -u. BUILD_DIR is
# captured alongside BIN because the SwiftPM resource bundles (Models.json, the
# tier manifest) live beside the binary and must be copied into the .app.
if [ -n "${SCRATCH_PATH:-}" ]; then
  swift build -c release --product LDAApp --scratch-path "$SCRATCH_PATH" >/dev/null
  BUILD_DIR="$(swift build -c release --product LDAApp --scratch-path "$SCRATCH_PATH" --show-bin-path)"
else
  swift build -c release --product LDAApp >/dev/null
  BUILD_DIR="$(swift build -c release --product LDAApp --show-bin-path)"
fi
BIN="$BUILD_DIR/LDAApp"

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

# SwiftPM resource bundles. LDAUI reads Models.json (the tier manifest) during
# startup; without it the packaged app has an empty catalog, the ladder
# collapses to Patterns only, and Manage Models shows nothing.
#
# They go in Contents/Resources, NOT the bundle root. SwiftPM's generated
# Bundle.module accessor looks in the root, but codesign rejects anything loose
# there with "unsealed contents present in the bundle root", so a root copy
# cannot be signed or notarized. ModelCatalog.load deliberately does not use
# Bundle.module: it searches Bundle.main.resourceURL as well, which is both the
# signable location and the conventional one for a macOS app.
echo "==> Bundling SwiftPM resource bundles"
FOUND_BUNDLE=0
for RB in "$BUILD_DIR"/*.bundle; do
  [ -e "$RB" ] || continue
  echo "    $(basename "$RB")"
  cp -R "$RB" "$APP/Contents/Resources/"
  # cp -R preserves the build directory's permissions, and some resource files
  # (ZIPFoundation's PrivacyInfo.xcprivacy) arrive read-only. The xattr strip
  # below then fails with EACCES and takes the whole script down AFTER the app
  # looks correctly assembled, which is the worst place to fail. Make the copy
  # writable so the strip and the signing that follows can do their work.
  chmod -R u+w "$APP/Contents/Resources/$(basename "$RB")"
  FOUND_BUNDLE=1
done
if [ "$FOUND_BUNDLE" -eq 0 ] || [ ! -f "$APP/Contents/Resources/LDACore_LDAUI.bundle/Models.json" ]; then
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
