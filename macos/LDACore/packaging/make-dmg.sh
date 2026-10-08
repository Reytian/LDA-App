#!/bin/bash
#
# Wrap a packaged LDA.app in a compressed disk image with an Applications
# link, the usual drag-to-install layout. Run it after package-app.sh: the app
# it wraps is already signed (and, for a release, notarized and stapled), and
# it already carries LDA V4, so installing from the image installs the model
# with the app.
#
#   APP_PATH           the packaged LDA.app (required)
#   DMG_PATH           where to write the image (default: beside the app,
#                      named LDA-<version>.dmg from the app's Info.plist)
#   CODESIGN_IDENTITY  Developer ID identity; signs the image itself
#   NOTARY_PROFILE     notarytool keychain profile; with CODESIGN_IDENTITY,
#                      notarizes and staples the image as well, so Gatekeeper
#                      accepts it offline
#
# House rules: English only. No em-dash or en-dash-as-separator.
set -euo pipefail

APP="${APP_PATH:?Set APP_PATH to the packaged LDA.app}"
if [ ! -d "$APP/Contents/Resources/LDA-V4" ]; then
  echo "!! $APP does not carry LDA V4 (Contents/Resources/LDA-V4); package it with package-app.sh first."
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="${DMG_PATH:-$(dirname "$APP")/LDA-$VERSION.dmg}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lda-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
echo "==> Staging LDA.app $VERSION"
ditto "$APP" "$STAGE/LDA.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "LDA $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Signing the disk image"
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  echo "!! NOTARY_PROFILE or CODESIGN_IDENTITY not set; the image is not notarized."
fi

echo "==> Done: $DMG"
/usr/bin/shasum -a 256 "$DMG"
