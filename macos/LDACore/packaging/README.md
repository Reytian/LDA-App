# Packaging LDA.app

Turns the SwiftPM `LDAApp` executable into a distributable, offline-by-design
macOS app bundle.

## Quick start (unsigned, for local use)

```bash
./packaging/package-app.sh
# produces dist/LDA.app  (open with right-click > Open the first time)
```

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

- `Contents/MacOS/LDAApp` : the app (statically links llama.cpp with Metal embedded).
- `LDACore_LDAUI.bundle` and `ZIPFoundation_ZIPFoundation.bundle` : SwiftPM resource
  bundles, at the bundle ROOT rather than in `Contents/Resources`, because that is
  where the generated resource accessor looks. `LDACore_LDAUI.bundle/Models.json`
  is the detection tier manifest. Without it the app degrades to an empty
  catalog: the ladder collapses to Patterns only and Manage Models is empty.
  `package-app.sh` exits non-zero rather than shipping such a build.
- `Contents/Info.plist` : bundle id `com.haotianyi.LDA` (change as needed).

**Only the Quick model is bundled** (`Contents/Resources/Qwen3.5-4B-Q4_K_M.gguf`,
about 2.7 GB, so the .app is roughly 3.2 GB). Quick peaks at 3.1 GB, which fits
the 16 GB minimum spec, so an offline user always has a model that actually runs
on their machine. Balanced needs 24 GB, so bundling that instead would hand a
16 GB user a model the memory gate blocks.

Balanced and Most thorough are downloaded through Model Management into
`Application Support/LDA/Models/`. `package-app.sh` exits non-zero if the Quick
model is missing rather than shipping a build with no working model.

## The privacy guarantee

`packaging/LDA.entitlements` turns the App Sandbox on and grants user-selected
file read/write, app-scoped bookmarks, and outbound network.

**The network entitlement is new, and the previous absolute claim that this app
never touches the network no longer holds.** It was added for one purpose:
downloading detection models the user explicitly requests in Settings, then AI,
then Manage Models.

What still holds, and what an auditor can verify:

- **Document content never leaves the machine.** Detection, redaction and
  restoration run entirely on-device against a local GGUF file. No document
  text, entity, mapping or filename is ever transmitted.
- The only outbound requests are model downloads, to the host recorded in
  `Models.json`, and only when a user starts one.
- No telemetry, no analytics, no crash reporting, no update check.
- `com.apple.security.network.server` is still absent: nothing connects in.

To audit: `grep -rn URLSession Sources/`. Every hit must sit behind Model
Management. Anything else is a defect.

Do not add `com.apple.security.network.server`.

## Not included

- An app icon (`AppIcon.icns`). Drop one in `Contents/Resources/` and add
  `CFBundleIconFile` to `Info.plist` before distribution.
- A hardened-runtime exception for JIT. If notarization rejects the Metal
  binary, uncomment `com.apple.security.cs.allow-jit` in the entitlements.
