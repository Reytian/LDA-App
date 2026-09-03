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
  bundles, in `Contents/Resources` rather than at the bundle ROOT, because
  codesign rejects loose files at the root with "unsealed contents present in
  the bundle root". `ModelCatalog.load` searches `Bundle.main.resourceURL` for
  exactly that reason instead of using the generated `Bundle.module` accessor.
  `LDACore_LDAUI.bundle/Models.json` is the detection tier manifest. Without it
  the app degrades to an empty catalog: the ladder collapses to Patterns only
  and Manage Models is empty. `package-app.sh` exits non-zero rather than
  shipping such a build.
- `Contents/Info.plist` : bundle id `com.haotianyi.LDA` (change as needed).

**No detection model is bundled by default**, so the shipping .app is about
16 MB and a fresh install asks for a model on first run: Manage Models
downloads one, or the user adds a file they carried over. Both paths verify the
file against the checksum in `Models.json` and copy it into
`Application Support/LDA/Models/`.

Set `BUNDLE_MODEL=1` to build a single-file deploy instead, with `MODEL_PATH`
pointing at the Quick GGUF. Only Quick is a candidate: it peaks at 3.1 GB and
fits the 16 GB minimum spec, where Balanced needs 24 GB and the memory gate
would block it. The script verifies the file's byte count and SHA-256 against
the packaged `Models.json` before copying it and exits non-zero on any
mismatch, because a bundled model is resolved straight through `Bundle.main`
and packaging is the only point at which it is ever checked. Bundling adds
2740937888 bytes, taking the .app to about 2.6 GiB.

Bundling is deliberately not inferred from a file being present at
`MODEL_PATH`: two builds of the same commit must produce the same app whatever
happens to be on the build machine.

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
