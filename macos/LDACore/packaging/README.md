# Packaging LDA.app

Turns the SwiftPM `LDAApp` executable into a distributable, offline-by-design
macOS app bundle.

## Quick start (local use)

```bash
./packaging/package-app.sh
# For an iCloud checkout, produces ~/Developer/lda-dist/LDA.app.
# Otherwise, produces dist/LDA.app.
```

The local build is ad hoc signed with the same App Sandbox and offline
entitlements as a distribution build. It is not notarized, so macOS may still
require right-click > Open the first time.

## Signed + notarized (for distribution)

You need an Apple Developer account.

1. Create a notarytool keychain profile once:

   ```bash
   xcrun notarytool store-credentials LDA_NOTARY \
     --apple-id you@example.com --team-id YOURTEAMID \
     --password APP_SPECIFIC_PASSWORD
   ```

2. Build, sign, notarize, and staple:

   ```bash
   CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
   NOTARY_PROFILE=LDA_NOTARY \
   ./packaging/package-app.sh
   ```

## What is in the bundle

- `Contents/MacOS/LDAApp`: the app (statically links llama.cpp with Metal embedded).
- `Contents/Resources/lda-v2-Q4_K_M.gguf`: the bundled v2 model (set `MODEL_PATH` to override).
- `Contents/Info.plist`: bundle id `com.haotianyi.LDA` (change as needed).

## The offline guarantee

`packaging/LDA.entitlements` turns the App Sandbox on and grants only
user-selected file read/write plus app-scoped bookmarks so a model chosen in
Settings remains available after relaunch. The packaging script applies these
entitlements to local and distribution builds. It deliberately includes **no
network entitlement**, so the OS denies all network access. This is the core
privacy property for privileged documents. Do not add
`com.apple.security.network.*`.

## Not included

- An app icon (`AppIcon.icns`). Drop one in `Contents/Resources/` and add
  `CFBundleIconFile` to `Info.plist` before distribution.
- A hardened-runtime exception for JIT. If notarization rejects the Metal
  binary, uncomment `com.apple.security.cs.allow-jit` in the entitlements.
