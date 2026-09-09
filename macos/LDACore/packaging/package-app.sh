#!/bin/bash
#
# Build LDA.app as a distributable macOS bundle, optionally code-signed and
# notarized. Every bundle is signed so the App Sandbox and offline entitlements
# are active. Local builds use an ad hoc signature; distribution builds use the
# Developer ID identity supplied by the caller.
#
# Always builds:
#   - Release LDAApp binary via SwiftPM
#   - LDA.app bundle (Info.plist + the static-linked binary + resource bundles)
#
# No detection model is bundled unless BUNDLE_MODEL=1 is set. The shipping
# build is model-less and asks for a model on first run.
#
# Optional (set to enable):
#   CODESIGN_IDENTITY  optional Developer ID identity for distribution, e.g.
#                      "Developer ID Application: Your Name (TEAMID)"
#   PROVISIONING_PROFILE
#                      path to the Developer ID provisioning profile
#                      ("LDA Developer ID" in the portal). REQUIRED whenever
#                      CODESIGN_IDENTITY is set: the distribution entitlements
#                      carry restricted keys that macOS honours only when the
#                      profile is embedded, and a build that claims them
#                      without it is killed at exec. Ignored for ad hoc builds.
#   NOTARY_PROFILE     a notarytool keychain profile name created with:
#                        xcrun notarytool store-credentials NOTARY_PROFILE \
#                          --apple-id you@example.com --team-id TEAMID \
#                          --password APP_SPECIFIC_PASSWORD
#   BUNDLE_MODEL       set to 1 to copy the Quick model into the bundle, for a
#                      single-file deploy. The file is verified against the
#                      packaged Models.json first and the script refuses to
#                      bundle anything that does not match. Unset means no
#                      model ships, which is the normal distributable.
#   MODEL_PATH         Quick model GGUF to bundle, read ONLY when BUNDLE_MODEL=1
#                      (default ~/Developer/lda-models/Qwen3.5-4B-Q4_K_M.gguf)
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
# allowed". An iCloud checkout therefore defaults to ~/Developer/lda-dist.noindex;
# other checkouts default to the package-local dist directory.
DEFAULT_DIST="$PKG/dist"
case "$PKG" in
  *"/Mobile Documents/"*|*"/Documents/"*) DEFAULT_DIST="$HOME/Developer/lda-dist.noindex" ;;
esac
DIST="${DIST_PATH:-$DEFAULT_DIST}"
APP="$DIST/LDA.app"
# No model is bundled by default. A fresh install gets its detection model
# either by downloading it through Manage Models or by importing a file the
# user carried over, and both paths verify the file against the checksum in
# Models.json. Bundling is opt in (BUNDLE_MODEL=1) for a single-file deploy,
# and only Quick is a candidate: it peaks at 3.1 GB so it fits the 16 GB
# minimum spec, where Balanced needs 24 GB.
#
# Bundling is deliberately NOT inferred from the presence of a file at
# MODEL_PATH. Two builds of the same commit must ship the same app whatever
# happens to be sitting in a directory on the build machine.
MODEL_PATH="${MODEL_PATH:-$HOME/Developer/lda-models/Qwen3.5-4B-Q4_K_M.gguf}"

case "$DIST" in
*"/Mobile Documents/"*|*"/Documents/"*)
  echo "!! Refusing to sign inside an iCloud-synced path ($DIST)."
  echo "!! Set DIST_PATH to a non-iCloud location, e.g. DIST_PATH=~/Developer/lda-dist.noindex"
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
# The standard macOS About panel loads Credits.html from the app resources.
cp "$PKG/packaging/Credits.html" "$APP/Contents/Resources/Credits.html"
cp "$PKG/../../LICENSE" "$APP/Contents/Resources/LICENSE.txt"
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

# Every string in the app now reaches the interface through
# L10n.text / L10n.button / .l10nHelp / L10n.string and their siblings, which
# resolve against LDACore_LDAUI.bundle's own nested .lproj folders directly
# (see Localization.swift) rather than through Bundle.main's
# localization-aware initializers. Promoting a copy into Contents/Resources
# used to be required because those initializers only look in the host app
# bundle.
#
# When this promotion was removed, the justification written here claimed no
# implicit LocalizedStringKey site was left in a localizing position. That was
# not true at the time: LocalizationRoutingTests was a RATCHET that still
# budgeted 302 literal sites and 47 LocalizedStringKey occurrences, and the
# app shipped with the drop zone, the mode tabs and the export buttons in
# English while the picker said 简体中文. The claim is true now because both
# budgets were driven to zero and the tables are empty, so the test is a real
# ban rather than a ceiling. Keep it that way: if either table is ever
# repopulated, this promotion is load-bearing again and its removal has to be
# revisited, because leaving it out means a budgeted implicit literal renders
# English in the packaged app instead of the picked language.
echo "==> Verifying interface localizations"
CATALOG_BUNDLE="$APP/Contents/Resources/LDACore_LDAUI.bundle"
for IDENTIFIER in en fr zh-Hans zh-Hant; do
  LOWER_IDENTIFIER="$(echo "$IDENTIFIER" | tr '[:upper:]' '[:lower:]')"
  if [ ! -f "$CATALOG_BUNDLE/$IDENTIFIER.lproj/Localizable.strings" ] \
     && [ ! -f "$CATALOG_BUNDLE/$LOWER_IDENTIFIER.lproj/Localizable.strings" ]; then
    echo "!! Missing $IDENTIFIER interface localization in $CATALOG_BUNDLE."
    echo "!! Refusing to ship an app with incomplete language support."
    exit 1
  fi
done

# A bundled model is resolved through ModelCatalog.bundledPath straight to
# Bundle.main.path(forResource:ofType:) and is never seen by ModelInstaller,
# so packaging is the only moment in the product's whole life when a bundled
# model can be checked at all. Skip the check here and the file is never
# verified by anything, ever. Size first because it is cheap and it names the
# likely cause (a truncated copy), then the digest.
MANIFEST="$APP/Contents/Resources/LDACore_LDAUI.bundle/Models.json"
if [ "${BUNDLE_MODEL:-0}" != "1" ]; then
  echo "==> No model bundled (BUNDLE_MODEL is not set). First run will offer a download or an offline import."
  BUNDLED_MODEL_NAME=""
else
  if [ ! -f "$MODEL_PATH" ]; then
    echo "!! BUNDLE_MODEL is set but there is no model file at $MODEL_PATH."
    echo "!! Set MODEL_PATH to the Quick model GGUF, or unset BUNDLE_MODEL to ship without one."
    exit 1
  fi
  MODEL_NAME="$(basename "$MODEL_PATH")"
  # Absolute paths on purpose: PATH is prepended by the test harness, and a
  # stubbed shasum would make this check meaningless. One awk pass extracts
  # both figures for the record whose fileName contains the basename of
  # MODEL_PATH; index() rather than a regex match so a dot in the file name is
  # not a wildcard.
  EXPECTED="$(/usr/bin/awk -v want="$MODEL_NAME" '
    /"fileName"/ { name = $0 }
    /"sizeBytes"/ { if (match($0, /[0-9]+/)) bytes = substr($0, RSTART, RLENGTH) }
    /"sha256"/ {
      if (index(name, want) > 0 && match($0, /[0-9a-f]{64}/)) {
        print bytes, substr($0, RSTART, RLENGTH); exit
      }
    }
  ' "$MANIFEST")"
  EXPECTED_BYTES="$(printf '%s' "$EXPECTED" | /usr/bin/awk '{print $1}')"
  EXPECTED_SHA="$(printf '%s' "$EXPECTED" | /usr/bin/awk '{print $2}')"
  if [ "${#EXPECTED_SHA}" -ne 64 ] || [ -z "$EXPECTED_BYTES" ]; then
    echo "!! Could not read the Quick tier checksum from the packaged Models.json."
    echo "!! Refusing to bundle a model that cannot be verified."
    exit 1
  fi
  ACTUAL_BYTES="$(/usr/bin/stat -f%z "$MODEL_PATH")"
  if [ "$ACTUAL_BYTES" != "$EXPECTED_BYTES" ]; then
    echo "!! $MODEL_NAME is $ACTUAL_BYTES bytes; Models.json expects $EXPECTED_BYTES."
    echo "!! Refusing to bundle a file that is not the published Quick model."
    exit 1
  fi
  ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$MODEL_PATH" | /usr/bin/awk '{print $1}')"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "!! $MODEL_NAME does not match the checksum published in Models.json."
    echo "!! Refusing to bundle an unverified model."
    exit 1
  fi
  echo "==> Bundling Quick model ($(du -h "$MODEL_PATH" | cut -f1)), checksum verified"
  cp "$MODEL_PATH" "$APP/Contents/Resources/$MODEL_NAME"
  BUNDLED_MODEL_NAME="$MODEL_NAME"
fi

# Strip extended attributes first. macOS stamps files with xattrs such as
# com.apple.provenance (on execution) and com.apple.quarantine / iCloud
# sync metadata (on a copied model, when one was bundled), and codesign
# refuses any file carrying a "resource fork, Finder information, or similar
# detritus".
xattr -cr "$APP"

SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
TIMESTAMP_ARGS=(--timestamp=none)
ENTITLEMENTS="$PKG/packaging/LDA.entitlements"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Developer ID signing with hardened runtime"
  TIMESTAMP_ARGS=(--timestamp)
  # A Developer ID build carries the RESTRICTED entitlements Touch ID needs
  # (application identifier, keychain access group). macOS honours those only
  # when the granting provisioning profile is embedded in the bundle; a binary
  # that claims them without it is SIGKILLed at exec before its first line.
  # So a signed build without a profile is refused here rather than produced.
  if [ -z "${PROVISIONING_PROFILE:-}" ]; then
    echo "!! CODESIGN_IDENTITY is set but PROVISIONING_PROFILE is not."
    echo "!! The distribution entitlements include com.apple.application-identifier and"
    echo "!! keychain-access-groups, which are honoured only with an embedded Developer ID"
    echo "!! provisioning profile. Without one the app is killed at launch."
    echo "!! Set PROVISIONING_PROFILE=/path/to/LDA_Developer_ID.provisionprofile"
    echo "!! (portal profile \"LDA Developer ID\"; see packaging/README.md), or unset"
    echo "!! CODESIGN_IDENTITY for an ad hoc build."
    exit 1
  fi
  if [ ! -f "$PROVISIONING_PROFILE" ]; then
    echo "!! PROVISIONING_PROFILE points at a file that does not exist: $PROVISIONING_PROFILE"
    exit 1
  fi
  # Inside the seal: codesign hashes Contents/, so the profile must be in place
  # BEFORE signing or the signature does not cover it and the grant is void.
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$PKG/packaging/LDA-distribution.entitlements"
else
  echo "==> Ad hoc signing for local use with App Sandbox enabled"
fi

# Sign the executable first, then the bundle, with the chosen entitlements.
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/LDAApp"
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
echo "==> Verifying signature and sandbox entitlements"
codesign --verify --strict --verbose=2 "$APP"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  # Read the entitlements back OUT of the sealed bundle and check them against
  # the embedded profile. Trusting the file that went in is how the previous
  # releases shipped a Touch ID promise nothing enforced. plistlib rather than
  # `plutil -extract`, which treats the dots in these key names as a key path.
  echo "==> Verifying restricted entitlements against the embedded profile"
  codesign -d --entitlements - --xml "$APP" > "$DIST/.entitlements.plist" 2>/dev/null
  security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$DIST/.profile.plist"
  /usr/bin/python3 - "$DIST/.entitlements.plist" "$DIST/.profile.plist" <<'PYCHECK'
import plistlib, sys
ents = plistlib.load(open(sys.argv[1], 'rb'))
prof = plistlib.load(open(sys.argv[2], 'rb'))
grants = prof.get('Entitlements', {})
fail = []
app_id = ents.get('com.apple.application-identifier')
team = ents.get('com.apple.developer.team-identifier')
groups = ents.get('keychain-access-groups') or []
if not app_id: fail.append('signed bundle carries no com.apple.application-identifier')
if not team: fail.append('signed bundle carries no com.apple.developer.team-identifier')
if not groups: fail.append('signed bundle carries no keychain-access-groups')
if app_id and grants.get('com.apple.application-identifier') != app_id:
    fail.append(f"profile grants application-identifier {grants.get('com.apple.application-identifier')!r}, bundle claims {app_id!r}")
allowed = grants.get('keychain-access-groups') or []
def covered(g):
    return any(g == a or (a.endswith('.*') and g.startswith(a[:-1])) for a in allowed)
for g in groups:
    if not covered(g):
        fail.append(f"keychain group {g!r} is not within the profile allowlist {allowed!r}")
if not ents.get('com.apple.security.app-sandbox'):
    fail.append('app-sandbox is no longer set on the signed bundle')
if fail:
    for f in fail: print('!! ' + f)
    sys.exit(1)
print(f"    application-identifier: {app_id}")
print(f"    keychain-access-groups: {groups}  (profile allows {allowed})")
print(f"    profile: {prof.get('Name')}  expires {prof.get('ExpirationDate')}")
PYCHECK
  rm -f "$DIST/.entitlements.plist" "$DIST/.profile.plist"
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
  echo "!! NOTARY_PROFILE not set (or no Developer ID identity); skipping notarization."
fi

echo "==> Done: $APP"
if [ -z "$BUNDLED_MODEL_NAME" ]; then
  echo "    Model: not bundled. First run offers a download or an offline import."
else
  echo "    Model: $BUNDLED_MODEL_NAME bundled and checksum verified."
fi
