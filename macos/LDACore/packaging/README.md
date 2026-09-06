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

2. Create the Developer ID provisioning profile once. This is what lets Touch
   ID protect the app's keychain keys; see "Why the profile" below.

   In [developer.apple.com](https://developer.apple.com/account) > Certificates,
   Identifiers & Profiles:

   - **Identifiers > + > App IDs > App**: register an *explicit* macOS App ID
     for the bundle identifier in `packaging/Info.plist` (`com.haotianyi.LDA`).
     No capability toggles are needed; keychain access is implicit in every
     profile.
   - **Profiles > + > Distribution > Developer ID** (macOS): select that App
     ID, then select your **existing** Developer ID Application certificate.
     Do not create a new certificate: the profile pins one, and notarization
     already trusts the one you have.
   - Download the `.provisionprofile`. Keep it somewhere stable and outside
     iCloud (this project uses `~/Developer/lda-signing/`), and back it up in
     your password manager as a document. Do not double-click it; that installs
     it into Xcode's store, which this script does not use.

   Sanity-check what you downloaded before using it:

   ```bash
   security cms -D -i ~/Developer/lda-signing/LDA_Developer_ID.provisionprofile \
     | plutil -p - | grep -E "application-identifier|keychain-access-groups|ExpirationDate"
   ```

   You should see `com.apple.application-identifier` = `YOURTEAMID.com.haotianyi.LDA`
   and `keychain-access-groups` containing `YOURTEAMID.*`.

3. Build, sign, notarize, and staple:

   ```bash
   CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
   PROVISIONING_PROFILE=~/Developer/lda-signing/LDA_Developer_ID.provisionprofile \
   NOTARY_PROFILE=LDA_NOTARY \
   ./packaging/package-app.sh
   ```

   `PROVISIONING_PROFILE` is required whenever `CODESIGN_IDENTITY` is set; the
   script refuses to sign without it rather than produce a build that dies at
   launch. The profile is copied to `LDA.app/Contents/embedded.provisionprofile`
   BEFORE signing so it sits inside the seal, and the signature uses
   `packaging/LDA-distribution.entitlements`, which is `LDA.entitlements` plus the
   three restricted keys. Ad hoc builds (no `CODESIGN_IDENTITY`) ignore the
   profile and use `LDA.entitlements` unchanged.

   After signing, the script reads the entitlements back OUT of the sealed
   bundle and checks them against the embedded profile: the application
   identifier must match, every claimed keychain group must sit inside the
   profile's allowlist, and the sandbox must still be on. Trusting the file
   that went in is how earlier releases shipped a Touch ID promise nothing
   enforced.

### Why the profile

The app protects its keychain keys with Touch ID by storing them behind a
user-presence access control. Items with an access control live only in the
data-protection keychain, and macOS builds that keychain's list of access
groups from the app's code-signing entitlements. A plain Developer ID
signature carries no application identifier, so it has no group: the protected
`SecItemAdd` returns `errSecMissingEntitlement` (-34018) and the app falls back
to an unprotected key, silently. Every release before the profile existed did
exactly that.

For Developer ID distribution the only thing that grants those entitlements is
an embedded provisioning profile. Claiming them in the signature without the
profile is worse than omitting them: the binary is killed at exec (SIGKILL,
exit 137) before it prints a line. That is why the restricted keys live in a
separate `LDA-distribution.entitlements`, why the script only uses that file
when a profile is present, and why `PackagingEntitlementsTests` pins the ad hoc
file as carrying none of them.

### Renewal

The profile document itself is valid until 2044, but it pins the Developer ID
Application certificate it was generated against, and that certificate expires
(currently 2027-02-01). Already-shipped notarized builds keep launching after
that date; their signatures are timestamped. **New** builds after the
certificate is renewed need a regenerated profile: Profiles > select "LDA
Developer ID" > Edit > pick the new certificate > Save, download, replace the
file. The script's verify step will otherwise fail on the certificate check.

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
