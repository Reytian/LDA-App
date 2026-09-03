# LDA.app Model Management: Functional Specification

**Date**: 2026-08-29
**Type**: PRD / functional specification
**Owner**: Product
**Status**: Superseded in part, 2026-09-03 (the bundled model is gone; see the note below)
**Applies to**: `macos/LDACore` (LDAUI, LDACore, LDAApp, packaging)
**Companion**: [model-tiers-prd.md](model-tiers-prd.md). That document decides *which* models exist and *how they are chosen*. This one decides *how they get onto the Mac, how they are proven, and how they leave*.


> **Superseded in part, 2026-09-03.** The app no longer bundles a model. `package-app.sh`
> ships a model-less build by default and bundles one only when `BUNDLE_MODEL=1` is set,
> in which case it verifies the file against the checksum in `Models.json` first. Every
> statement below that a model "ships inside the app", and the settled decision recorded
> in section 1 that "the app bundle ships exactly one model, Quick", are reversed: the
> tiers PRD's Appendix N position (nothing is bundled) is the shipping design again.
> A fresh install now installs a model in one of two ways, either an in-app download or a
> checksum-verified import of a file the user supplies, which is also the only remedy for
> a machine running with offline mode forced on. See `macos/LDACore/README.md`, section
> "Installing a detection model".

---

## TL;DR

- Two decisions arrive from outside this document and are treated as settled: **the app gains `com.apple.security.network.client`, used only for model downloads**, and **the app bundle ships exactly one model, Quick**. Appendix N of the tiers PRD ("nothing is bundled") is superseded.
- The consequence that needs the most care is not the download UI. It is that **the offline guarantee stops being enforced by the operating system and starts being enforced by us**. A firm's security reviewer could previously verify it in five seconds by reading one file. This spec replaces that with four things a reviewer can still check cheaply, and makes one of them a CI assertion.
- **Manage Models** becomes a sheet listing every model with a plain-language annotation a lawyer can act on, plus download, verify, and remove.
- **A model the Mac cannot run cannot be downloaded.** Apple Silicon memory is soldered, so a blocked tier is blocked forever on that machine, and the ladder would refuse to select the file even after it arrived.
- **Removing the model in use is allowed**, behind a confirmation that names the setting it will drop to, computed before the click.
- **Blocking release item**: all three `sha256` fields in `Models.json` are empty strings today and the Qwen3.8-27B `sourceURL` was never verified. Downloading an unverifiable 13 GB file into a redaction tool is a worse product than not shipping the tier.

---

## Core decision card

| Item | Content |
|---|---|
| Recommended approach | A Manage Models sheet with per-model annotations, in-app download from an allowlisted host, three-layer verification, and removal with deterministic demotion. Network access is confined to one Swift type, asserted by CI. |
| Priority | P0: the manifest completeness gate, the restated network copy, the download state machine, removal with demotion. P1: resume across relaunch, throughput display, duplicate-copy cleanup. |
| Expected impact | Balanced and Most thorough become reachable for the 24 GB and 32 GB users who can run them, without an eight-step browser detour. The 16 GB user is unaffected and unharmed. |
| Resource need | One engineer, roughly two weeks, plus one measurement pass to fill the manifest hashes and confirm the third URL. |
| Risk level | **High**, concentrated in one place. See section 11. The download code is routine; the permanent change to how the privacy claim is verified is not. |

---

## 1. Goals and non-goals

### 1.1 Goals

**G1. A lawyer can choose a model without being shown a score.** Every model carries an annotation written in consequences: what it catches, what it misses, what it costs in wait and in review, and what Mac it needs.

**G2. Getting a model is one button.** The clipboard-and-browser flow in tiers PRD section 4.3 was designed around a constraint that no longer applies. It stays as a manual fallback, but it is not the primary path.

**G3. The privacy claim stays true, stays specific, and stays checkable.** No hedging, no asterisk, no "we do not sell your data" evasion. A statement a security reviewer can test in an afternoon and find accurate.

**G4. Nothing installs unverified.** A file that reaches the model store either matches the published hash or is labelled as something the app cannot vouch for. There is no third state where the app quietly hopes.

**G5. Removal is real.** Disk actually comes back, the number reported is the number reclaimed, and the app never ends up pointing at a file it just deleted.

**G6. No route into an unusable outcome.** The app does not let a user spend 13 GB of a firm's bandwidth and SSD on a model it will then refuse to select.

### 1.2 Non-goals

- **No background or automatic downloads.** Nothing transfers without a click on a button labelled with the size. No prefetch, no "we noticed you have 32 GB", no update check.
- **No update check of any kind.** The app never asks a server whether a newer model or a newer LDA exists. That would be a periodic outbound connection with no user action behind it, which is exactly the property section 2 promises does not exist.
- **No telemetry, no crash reporting, no analytics.** Unchanged from the tiers PRD, and now load-bearing: with a network entitlement present, "we collect nothing" is a claim rather than a physical impossibility, so it must be stated and testable.
- **No model hosting of our own.** We link to the upstream repository. We do not mirror, proxy, or re-host. A mirror would mean running a service that sees which firm downloads what.
- **No download for the CLI or MCP surfaces.** `lda anonymize --model` and the MCP `modelPath` argument stay file-path arguments. The command line does not acquire a network path in this release.
- **No sharing of one downloaded model between the GUI and a second Mac.** The store is inside the app container by design (tiers PRD 4.4). An IT-deployable model package remains the deferred item it already was.
- **No change to detection, placeholders, the mapping format, or the encrypted container.**

---

## 2. The network promise, restated

### 2.1 What changed, stated plainly

Before this release the guarantee was structural: `packaging/LDA.entitlements` contained no network entitlement, so with the sandbox on, the kernel denied every socket operation. The app could not connect even if its code tried to.

After this release the app carries `com.apple.security.network.client`. The kernel will now permit outbound connections. Whether any happen, and to where, is decided by our code.

**This is a one-way change in the kind of evidence available.** It moves from *the OS forbids it* to *we do not do it*. The first is verified by reading one file. The second is verified by auditing a codebase, every release, forever. No amount of good copy closes that gap, and pretending otherwise in the UI would be the exact failure this product exists to prevent in other tools.

So the response has two halves: say the true thing (2.2), and manufacture a cheap substitute for the check we gave up (2.4 through 2.7).

### 2.2 The finished statement

Three lengths, one meaning. All three are production copy, not placeholders.

**Short, for the persistent on-device badge tooltip (`AppShell.bannerChrome`):**

> Your documents never leave this Mac. LDA uses the network for one thing only: downloading a detection model when you ask it to.

**Standard, for Settings > AI and the Manage Models sheet header:**

> Your documents never leave this Mac. Detection, redaction, and the encrypted mapping all run here, and nothing about a document is ever sent anywhere. LDA reaches the network for exactly one thing: fetching a detection model file when you press Download. It connects only to huggingface.co, only while a download you started is running, and it sends nothing but the request for that file.

**Long, for onboarding and for the security note in `packaging/README.md`:**

> LDA is an offline tool with one exception, and the exception is narrow enough to describe completely.
>
> Your documents never leave this Mac. Detection runs on a model stored on this Mac. Redaction, restoration, the placeholder mapping, and the encrypted store are all local. No part of a document, no filename, no placeholder, and no usage statistic is transmitted anywhere, ever. There is no telemetry, no crash reporting, and no update check.
>
> The one exception: LDA can download a detection model for you. That happens only when you press Download in Settings > AI, only to huggingface.co and its content servers, and only for the duration of that transfer. The request carries nothing but the name of the model file. Every downloaded file is checked against a published SHA-256 before it is installed, so a tampered or truncated file is rejected rather than used.
>
> If you would rather LDA never opened a connection at all, turn on Offline mode in Settings > AI. The model that ships inside the app keeps working.

Copy rules that produced this: no "we do not sell", no "industry standard", no "your privacy matters". State the scope, the trigger, the destination, the duration, and the payload. Five facts, each falsifiable.

### 2.3 Where each version appears

Every string in the codebase that currently claims total network isolation is now false and must change in this release. This is the complete inventory.

| # | Site | Current text | Action |
|---|---|---|---|
| C1 | `Sources/LDAUI/AppShell.swift:435` (on-device badge `.help`) | "Documents, placeholders, and mappings never leave this Mac. The app has no network access at all." | Replace second sentence with the **short** statement's second clause. |
| C2 | `Sources/LDAUI/OnboardingView.swift:70` | Already updated to the narrow claim. | Verify it matches the **long** statement's first two paragraphs. No further change expected. |
| C3 | `Sources/LDAUI/SettingsView.swift:242` (AITab footer) | Already updated to the narrow claim. | Replace with the **standard** statement verbatim so all surfaces agree word for word. |
| C4 | `packaging/README.md:50` "The offline guarantee" section | "It deliberately includes no network entitlement, so the OS denies all network access. Do not add `com.apple.security.network.*`." | Rewrite per 2.4. This is the section a security reviewer reads first. |
| C5 | `packaging/LDA.entitlements` | Prohibition comment on any network entitlement. | Replace with a scoped comment: client only, for model downloads, server still prohibited. |
| C6 | `Sources/LDAUI/AISettings.swift:24` header comment | "the offline guarantee in LDA.entitlements is untouched" | Update; the guarantee is now narrowed, not absolute. |
| C7 | New: Manage Models sheet header | none | The **standard** statement. |
| C8 | New: Settings > AI, Offline mode row | none | See 2.8. |

**AC-covered.** A grep for "no network access at all" over `Sources/` and `packaging/` must return zero hits after this release (MM-4).

### 2.4 What a security reviewer can verify

The five checks below are what replaces "read the entitlements file". Each is designed to be executable by someone who does not know Swift, in under an hour, against a signed build. `packaging/README.md` publishes them as a numbered list so the firm does not have to invent them.

| # | Check | How | Expected result |
|---|---|---|---|
| V1 | The app can only make outbound client connections, never accept inbound | `codesign -d --entitlements - /Applications/LDA.app` | `com.apple.security.network.client` present; `com.apple.security.network.server` absent; sandbox on. |
| V2 | Nothing connects during normal work | Open, scan, review, export, restore a document with `nettop -p <pid>` or Little Snitch running. Do not press Download. | Zero connection attempts across the entire session. |
| V3 | A download connects only to the published hosts | Press Download with the monitor running. | Connections resolve only to `huggingface.co`, `hf.co`, or their content hosts. Nothing else. |
| V4 | The connection closes when the download ends | Keep the monitor running for ten minutes after the transfer completes. | No further connections. No keepalive, no poll. |
| V5 | Only one place in the source can connect | `grep -rn "URLSession\|NWConnection\|CFStream\|NSWorkspace.open" Sources/` | Exactly one file matches: `Sources/LDAUI/ModelDownloader.swift`. |

V5 is the one that generalises. V1 through V4 test one build; V5 tells the reviewer where to look in every future build, and it is one command.

### 2.5 The single chokepoint invariant

**All network capability in the application lives in exactly one type, `ModelDownloader`, in exactly one file, `Sources/LDAUI/ModelDownloader.swift`.**

No other file in `Sources/` may reference `URLSession`, `URLRequest`, `NWConnection`, `CFReadStream`, `Network.framework`, or `NSWorkspace.open`. This is not a style preference. It is the thing that makes V5 a valid check, and V5 is the only cheap, repeatable check the reviewer has left.

Enforcement:

- A CI step greps `Sources/` for those symbols and fails on any match outside `ModelDownloader.swift` (MM-5).
- A unit test asserts the same thing over the source tree so a developer sees it before CI does.
- A header comment in `ModelDownloader.swift` states why the file exists and that adding a second one breaks a published security claim, in the same voice as the existing entitlements prohibition. Future readers "tidying up" is the realistic failure mode; the prior bookmark comment in `LDA.entitlements` exists for exactly this reason and is the model to copy.

### 2.6 The host allowlist, and the redirect trap

`ModelDownloader` refuses any URL whose host is not on the allowlist.

```
allowedHostSuffixes = ["huggingface.co", "hf.co"]
```

A host is allowed when it equals an entry or ends with "." plus an entry. `evil-huggingface.co` must not pass, which is why the match is on a dot-prefixed suffix rather than `hasSuffix`.

**The trap that a naive implementation will hit.** A HuggingFace `.../resolve/main/model.gguf` URL does not serve bytes. It answers `302` to a content host, currently in the `cas-bridge.xethub.hf.co` and `cdn-lfs*.hf.co` families, and those may change without notice. Two consequences, both required:

1. **The allowlist must be applied to every hop, not just the first.** Implement `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`, re-check the new host, and pass `nil` to the completion handler to refuse a redirect that leaves the allowlist. Failing to do this means the published claim "connects only to huggingface.co" is false the first time upstream changes CDN, and we would not find out.
2. **The allowlist entries must cover the content hosts, and this must be verified against the live service before release, not assumed.** If the CDN family is outside `hf.co`, the allowlist must name it explicitly and `packaging/README.md` must list it, because a reviewer running V3 will see it in the trace and a host we did not publish reads as a lie.

A refused redirect surfaces as failure branch **D5** and its message names the host that was refused, so the failure is diagnosable rather than mysterious.

Redirect count is capped at 5. `URLRequest` uses the default cache policy with caching disabled for the download task, and no cookies (`httpShouldHandleCookies = false`, an ephemeral `URLSessionConfiguration`). Nothing about this Mac should be identifiable across two downloads beyond what an anonymous HTTP GET necessarily reveals.

### 2.7 The transport is untrusted; the hash is the trust boundary

**Do not pin certificates.** Many firms run a TLS-inspecting proxy with an internally issued root CA distributed by MDM. Pinning would make LDA the one app on the machine that cannot download, and the workaround the user would then find is worse than the problem.

We can afford to use the system trust store because the transport is not what we are trusting. The file is verified against a SHA-256 published in the app bundle and covered by the app's own code signature. A proxy that inspects the transfer learns only which model file was requested. A proxy that *modifies* the transfer produces a hash mismatch and the file is deleted (D11).

State this in `packaging/README.md`. It converts what a reviewer might read as a weakness into the design's actual strength, and it is true.

### 2.8 Offline mode: decision and design

**Decision: ship it.** One toggle, `Settings > AI > Offline mode`, plus a managed-preference key so IT can force it.

The reasoning is not that it improves privacy for a typical user. It does not: without it, the app still connects only on a button press. It ships because the question a firm's reviewer actually asks is not "does it connect" but "**can I guarantee it will not**", and before this release the answer was a file they could read. Offline mode gives them an answer again, and it costs one boolean.

Design:

- **Default: off** (that is, network permitted, and dormant). The path it gates is already dormant until a click, so defaulting it on would only add a step for the user who wants Balanced, and generate "why is this greyed out" support load. Quick is bundled, so a fresh install works fully with zero connections regardless of this setting.
- **When on**: every Download control is disabled with the reason "Offline mode is on." Manual install through **Add a downloaded file** stays enabled, because it involves no connection. `ModelDownloader` refuses to construct a task at all, checked at the bottom of the stack rather than only in the view, so there is no route around it.
- **Managed preference**: read `com.haotianyi.LDA.offlineMode` from `UserDefaults.standard` in the normal way, so a configuration profile writing that key at the managed domain wins over a user default automatically. When the value comes from a managed profile, the toggle renders disabled with "Set by your organization". Detect via `UserDefaults.standard.objectIsForced(forKey:)`.
- **Honesty limit, stated in the UI**: the row's help text reads "This stops LDA from downloading models. It is a setting inside LDA, not a firewall." Do not let a checkbox imply a guarantee it cannot make. A reviewer who needs enforcement uses a firewall or an MDM network policy, and telling them so is the credible move.

New key in `AISettings`:

```
public static let offlineModeKey = "com.haotianyi.LDA.offlineMode"
```

---

## 3. What ships in the bundle

**Decision (settled input): the app bundle contains exactly one model, Quick (Qwen3.5-4B Q4_K_M). The `.app` is roughly 3.2 GB.**

Appendix N of the tiers PRD, which specified that no weights ship at all, is **superseded**. Section 4.2 of that document is restored, and the reason is the minimum spec: the supported floor is a 16 GB Mac, Balanced needs 24 GB, and bundling Balanced would hand a 16 GB user a 7 GB file the memory gate refuses to select. Bundling Quick is the only choice that gives every supported machine a working model with zero setup and zero connections.

Consequences that must land with it:

- `package-app.sh` already implements this (it copies `MODEL_PATH`, defaulting to `Qwen3.5-4B-Q4_K_M.gguf`, and warns when absent). No change needed beyond section 4.2's validation gate.
- `ModelCatalog.bundledPath(for:)` and `isBundled(_:)` already exist in `ModelTiers.swift`. Both are correct.
- **`AITab.rungRow` is wrong today and must be fixed.** It computes `let installed = tier.map { ModelCatalog.isInstalled($0) } ?? false` under a stale comment reading "No tier ships inside the app any more". On a shipping build this marks Quick "Not installed" and refuses to select it, which is the one rung every user must have. Selectability must be `ModelCatalog.isInstalled(tier) || ModelCatalog.isBundled(tier)`. This is a live defect introduced by the Appendix N direction and is P0 (MM-9).
- `AISettings.resolveModelPath` already prefers the container copy and falls back to the bundle. That order is correct and stays, with one refinement in 7.4.
- `OnboardingView.modelAvailable` is true on a fresh install again. Its doc comment says the opposite and must be corrected.

---

## 4. The manifest

`Sources/LDAUI/Resources/Models.json` remains the single source of truth for the picker, the verifier, the memory gate, the time estimate, and now the download.

### 4.1 New fields

Added to `ModelTier` in `Sources/LDAUI/ModelTiers.swift`:

| Field | Type | Purpose |
|---|---|---|
| `runtimeRSSGB` | `Double` | Peak resident memory under the **production** `LLMEngine.Config` (Appendix M). Display only. Never used for gating. |
| `bundled` | `Bool` | Declares the intent to ship inside the app. Cross-checked against `bundledPath(for:) != nil` at launch; a disagreement is a packaging error and is logged. |
| `criticalFound` | `Int` | Critical entities found in the benchmark, for the annotation. |
| `criticalTotal` | `Int` | Critical entities in the benchmark corpus. Same for all tiers (36). |
| `falseFlagOneIn` | `Int` | Denominator of the dismiss rate, derived from precision. 5, 15, 8. |
| `modelDisplayName` | `String` | The upstream model name shown next to the tier name ("Qwen3.5-4B"). Distinct from `displayName`, which is the tier ("Quick"). |

**Two memory numbers, on purpose.** `peakRSSGB` (harness: 3.60 / 9.21 / 13.83) drives `MemoryGate`. `runtimeRSSGB` (production: 3.11 / 8.48 / 12.16) drives the sentence "uses about 8.5 GB of memory while it runs". They differ because the harness ran `-c 12288 -np 1` and production runs `-c 8192 -np 4`, which splits the KV pool across slots and lands lower (Appendix M). Gating on the higher number is deliberately conservative and stays.

An engineer will eventually notice these disagree and try to reconcile them. Both the manifest and `ModelTiers.swift` must carry a comment saying they are different questions with different answers: *what will this cost my Mac right now* versus *what size Mac may select this*. Reconciling them in either direction is a regression. A unit test asserts `runtimeRSSGB < peakRSSGB` for every tier, which is the invariant that makes the gate conservative (MM-14).

`minimumMacGB` is deliberately **not** a manifest field. It is derived by a new `MemoryGate.minimumInstalledGB(for:) -> Int` walking the same candidate ladder as the existing `requirementText`. One derivation, no drift.

### 4.2 Completeness rule: confirmed, and moved to build time

Tiers PRD section 4.6 requires that a tier with an incomplete manifest row be **hidden entirely**. **Confirmed.** An unverifiable model in a redaction tool is worse than an absent one, and now that we fetch the file ourselves rather than asking a user to, an unverifiable row is an invitation to install 13 GB of something we cannot identify.

**Revised in one respect: the rule is enforced at build time as well, and the build-time gate is the primary one.**

A tier row is **complete** when all of the following hold:

1. `fileName` is non-empty and ends `.gguf`
2. `sizeBytes > 0`
3. `sha256` matches `^[0-9a-f]{64}$`
4. `sourceURL` parses, uses `https`, and its host passes the section 2.6 allowlist
5. `peakRSSGB > 0` and `runtimeRSSGB > 0` and `runtimeRSSGB < peakRSSGB`
6. `architecture`, `blockCount`, `embeddingLength` are all populated
7. `criticalFound <= criticalTotal`, both `> 0`, and `falseFlagOneIn > 1`

Behaviour:

- **Build time**: `package-app.sh` validates every row and **fails the build** on any incomplete tier. Runtime hiding is a safety net, not a release plan. If we lean on it, we ship a one-rung app and find out from a user asking where Balanced went.
- **Runtime**: an incomplete row is hidden from the ladder and from Manage Models, and logged once at launch. This covers a corrupted or hand-edited manifest, not a normal release.

The completeness predicate lives in one place, `ModelCatalog.isComplete(_:) -> Bool`, called by the packaging validator, the ladder, and the sheet. Same lesson as everywhere else in this app: one gate, several call sites, never several gates.

### 4.3 Release blockers in `Models.json` as it stands

The shipped manifest fails its own completeness rule on every row. These are not nice-to-haves; the feature does not function without them.

| # | Row | Problem | Fix |
|---|---|---|---|
| B1 | all three | `"sha256": ""` | `shasum -a 256` each GGUF on the benchmark Mac. Without this, layer 3 verification cannot run and every download installs unverified. |
| B2 | `most-thorough` | `sourceURL` points at `unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q3_K_XL.gguf`. The tiers PRD flags that this model does not appear in `bench/CANDIDATES.md` and the URL "must not be guessed". It is currently a guess. | Confirm against the actual artifact the benchmark used. A wrong URL used to be a copy defect; now it is a 404 in the middle of a 13 GB feature. |
| B3 | all three | `runtimeRSSGB` absent | Add 3.11 / 8.48 / 12.16 from Appendix M. |
| B4 | all three | annotation inputs absent | Add `criticalFound` 35/35/36, `criticalTotal` 36, `falseFlagOneIn` 5/15/8, `modelDisplayName`. |
| B5 | `quick` | `bundled` absent | Add `true` for quick, `false` for the others. |
| B6 | all three | header fields for Balanced and Most thorough were never captured from the real artifacts (tiers PRD 4.6 open item) | Capture `general.architecture`, `block_count`, `embedding_length` via a `vocab_only` load. Note the current file claims `"architecture": "qwen35"` for the 27B row; confirm rather than assume. |

A unit test asserts `ModelCatalog.isComplete` for every shipped row. **It fails today, and that is the correct signal** (MM-13).

---

## 5. The Manage Models sheet

### 5.1 Placement and lifetime

The AI tab keeps the ladder from the tiers PRD. It gains a **Manage Models...** button below the ladder, and each model rung gains an inline progress bar while that model is downloading.

The sheet is presented from `AITab` but its state is **not** owned by it. Downloads run 5 to 35 minutes; a modal the user must stare at for half an hour is not acceptable, and a `@State` in a dismissed sheet takes the download with it.

**Requirement**: a single `ModelInstallStore` (`ObservableObject`, `@MainActor`) is created once at app scope in `LDAApp` and injected into the environment. It owns the state of every tier, the active `ModelDownloader` task, and the resume metadata. The sheet renders it; the AI tab renders it; dismissing the sheet does nothing to it. Closing the Settings window does nothing to it. Only Cancel cancels.

### 5.2 Wireframes

**W1. 16 GB Mac, fresh install.** Quick is built in; the other two are blocked and offer nothing.

```
+------------------------------------------------------------------------------+
|  Models                                                                 [x]   |
|                                                                               |
|  Your documents never leave this Mac. Detection, redaction, and the           |
|  encrypted mapping all run here, and nothing about a document is ever sent    |
|  anywhere. LDA reaches the network for exactly one thing: fetching a          |
|  detection model file when you press Download. It connects only to            |
|  huggingface.co, only while a download you started is running, and it sends   |
|  nothing but the request for that file.                                       |
|                                                                               |
|  Which should I choose?                                                       |
|  Quick is built in and works on every Mac LDA supports. With 24 GB of memory  |
|  or more, Balanced finds the same amount and leaves you far less to dismiss.  |
|  Most thorough is the only one that missed nothing in our testing.            |
|                                                                               |
|  ---------------------------------------------------------------------------  |
|                                                                               |
|  Quick   Qwen3.5-4B                                     Built in   [In use]   |
|                                                                               |
|  Finds names, companies, and addresses on every kind of contract we tested,   |
|  and it is the only setting that runs on a 16 GB Mac. In our twelve document  |
|  test set it found 35 of the 36 names, companies, and addresses that had to   |
|  be caught. It is the least precise of the three: about one flag in five is   |
|  something you will look at and dismiss, so reviewing takes longer than       |
|  waiting does.                                                                |
|                                                                               |
|  2.74 GB, inside the app   ~3.1 GB of memory   ~53 seconds a contract         |
|  Needs a Mac with 16 GB of memory. This Mac has 16 GB.                        |
|  Built in and verified. Part of the app, so it cannot be removed.             |
|                                                                               |
|  ---------------------------------------------------------------------------  |
|                                                                               |
|  Balanced   gemma-4-12b                                                       |
|                                                                               |
|  The best all round choice when your Mac has the memory. It found the same    |
|  35 of 36 as Quick and is by far the tidiest to review: only about one flag   |
|  in fifteen is something you will dismiss. It reports what it finds in        |
|  exactly the wording of your document, so nothing is lost between finding a   |
|  name and redacting it.                                                       |
|                                                                               |
|  7.12 GB download   ~8.5 GB of memory   ~2 min 15 sec a contract              |
|  Needs a Mac with 24 GB of memory. This Mac has 16 GB.                        |
|  Cannot run on this Mac, so it is not offered for download.                   |
|                                                                               |
|  ---------------------------------------------------------------------------  |
|                                                                               |
|  Most thorough   Qwen3.8-27B                                                  |
|                                                                               |
|  The only setting that missed nothing. On the same test set it found all 36   |
|  names, companies, and addresses, including the one Quick and Balanced both   |
|  missed. You pay for that twice: it takes about twice as long as Balanced,    |
|  and it flags more that you will dismiss, roughly one in eight. Choose it     |
|  for the document you cannot afford to get wrong.                             |
|                                                                               |
|  13.15 GB download   ~12.2 GB of memory   ~4 min 25 sec a contract            |
|  Needs a Mac with 24 GB of memory. This Mac has 16 GB.                        |
|  Cannot run on this Mac, so it is not offered for download.                   |
|                                                                               |
|  ---------------------------------------------------------------------------  |
|  Use another model                                                            |
|  Any local GGUF file. LDA cannot tell you how well it will work, how long it  |
|  will take, or how much memory it needs.            [ Choose File... ]        |
|                                                                               |
|  Models live inside LDA's own folder on this Mac. 0 bytes downloaded.         |
|  214 GB free on this disk.                                                    |
|                                                                               |
|  Figures come from a test set of twelve contracts in English and Chinese.     |
|  Your documents will differ.                                                  |
+------------------------------------------------------------------------------+
```

**W2. 32 GB Mac, Balanced downloading.** Note that the sheet can be closed and the transfer continues.

```
|  Balanced   gemma-4-12b                                                       |
|                                                                               |
|  [annotation, as above]                                                       |
|                                                                               |
|  7.12 GB download   ~8.5 GB of memory   ~2 min 15 sec a contract              |
|  Needs a Mac with 24 GB of memory. This Mac has 32 GB.                        |
|                                                                               |
|  Downloading                                                    [ Cancel ]    |
|  [##################################----------------------]  3.9 of 7.12 GB   |
|  6.4 MB a second, about 8 minutes left                                        |
|  You can close this window. The download keeps going.                         |
```

**W3. Verifying, after the bytes are in.**

```
|  Checking the file                                                            |
|  [#############################################-------------]  78%           |
|  Making sure this is the model we tested.                                     |
```

**W4. Installed, and a removal confirmation for the model in use.**

```
|  Most thorough   Qwen3.8-27B                       Installed  [In use]        |
|  13.15 GB on disk   ~12.2 GB of memory   ~4 min 25 sec a contract             |
|  Verified 29 Aug 2026.                              [ Remove ]                |
```

Pressing Remove, when this is the setting in use and Balanced is also installed:

```
+--------------------------------------------------------------+
|  Remove Most thorough?                                        |
|                                                               |
|  This is the setting you are using now. Removing it frees      |
|  13.15 GB and switches detection to Balanced.                 |
|                                                               |
|                     [ Cancel ]  [ Remove and switch ]         |
+--------------------------------------------------------------+
```

And when it is the only installed model beyond the built-in one, the consequence changes and so does the copy:

```
+--------------------------------------------------------------+
|  Remove Balanced?                                             |
|                                                               |
|  This is the setting you are using now. Removing it frees      |
|  7.12 GB and switches detection to Quick, which finds the      |
|  same names but leaves more for you to dismiss.               |
|                                                               |
|                     [ Cancel ]  [ Remove and switch ]         |
+--------------------------------------------------------------+
```

The Patterns only case, which can only arise if the bundled model is somehow absent, gets the strongest wording because it changes what is redacted:

```
|  Removing it frees 7.12 GB and switches detection to Patterns  |
|  only, which does not find names, companies, or addresses at   |
|  all.                                                          |
|                                                               |
|              [ Cancel ]  [ Remove and stop finding names ]     |
```

**W5. A failure.** Every failure names what happened, what it cost, and what to do.

```
|  Balanced   gemma-4-12b                                                       |
|                                                                               |
|  Download failed                                                              |
|  The connection was lost after 3.9 of 7.12 GB. What downloaded so far is      |
|  kept, so resuming does not start over.                                       |
|                                            [ Discard ]  [ Resume ]            |
```

```
|  Download failed                                                              |
|  The file that arrived is not the Balanced model we published. It may have    |
|  downloaded incompletely, or the copy on the server may have changed. The     |
|  file was deleted and nothing was installed.                                  |
|                                                    [ Try again ]              |
```

**W6. The AI tab row while a download runs.** The user does not have to keep the sheet open to see progress.

```
|  ( )  Balanced                          about 2 min per contract              |
|       Finds a little more than Quick and flags less that you have             |
|       to dismiss.                                                             |
|       [##################-----------]  Downloading, 3.9 of 7.12 GB            |
```

### 5.3 Full annotation copy

Production English. No scores, no decimals, no em-dash or en-dash. Numbers in braces interpolate from the manifest so prose and data cannot drift (see 5.3.1).

---

**Quick** / Qwen3.5-4B

> Finds names, companies, and addresses on every kind of contract we tested, and it is the only setting that runs on a 16 GB Mac. In our twelve document test set it found {criticalFound} of the {criticalTotal} names, companies, and addresses that had to be caught. It is the least precise of the three: about one flag in {falseFlagOneIn} is something you will look at and dismiss, so reviewing takes longer than waiting does.

Facts line: `{downloadSize}, inside the app` (when bundled) or `{downloadSize} download` · `~{runtimeRSS} of memory` · `~53 seconds a contract`
Requirement line: `Needs a Mac with {minimumMacGB} GB of memory. This Mac has {installedGB} GB.`
Status line (bundled): `Built in and verified. Part of the app, so it cannot be removed.`

---

**Balanced** / gemma-4-12b

> The best all round choice when your Mac has the memory. It found the same {criticalFound} of {criticalTotal} as Quick and is by far the tidiest to review: only about one flag in {falseFlagOneIn} is something you will dismiss. It reports what it finds in exactly the wording of your document, so nothing is lost between finding a name and redacting it.

Facts line: `7.12 GB download` · `~8.5 GB of memory` · `~2 min 15 sec a contract`
Requirement line: `Needs a Mac with 24 GB of memory. This Mac has {installedGB} GB.`

---

**Most thorough** / Qwen3.8-27B

> The only setting that missed nothing. On the same test set it found all {criticalTotal} names, companies, and addresses, including the one Quick and Balanced both missed. You pay for that twice: it takes about twice as long as Balanced, and it flags more that you will dismiss, roughly one in {falseFlagOneIn}. Choose it for the document you cannot afford to get wrong.

Facts line: `13.15 GB download` · `~12.2 GB of memory` · `~4 min 25 sec a contract`
Requirement line: `Needs a Mac with 24 GB of memory. This Mac has {installedGB} GB.`

---

**Use another model** (not a tier; the escape hatch row)

> Any local GGUF file. LDA cannot tell you how well it will work, how long it will take, or how much memory it needs. It overrides the setting above until you stop using it.

---

**Sheet footer, always present**

> Figures come from a test set of twelve contracts in English and Chinese. Your documents will differ.

---

**Status line, by state**

| State | Line |
|---|---|
| Built in | `Built in and verified. Part of the app, so it cannot be removed.` |
| Not installed, runnable | `Not installed.` with a `[ Download 7.12 GB ]` button |
| Not installed, blocked | `Cannot run on this Mac, so it is not offered for download.` and no button |
| Downloading | `Downloading` plus bar, `{written} of {total}`, `{rate} a second, about {eta} left`, `You can close this window. The download keeps going.` |
| Paused | `Paused at 3.9 of 7.12 GB.` with `[ Resume ]` and `[ Discard ]` |
| Verifying | `Checking the file` plus bar, `Making sure this is the model we tested.` |
| Installed, verified | `Verified {date}.` with `[ Remove ]` |
| Installed, unverified | `Installed, but LDA could not confirm this is the model it published. Results may differ from what is described above.` with `[ Remove ]` |
| Offline mode on | `Offline mode is on, so LDA will not download. You can still add a file you downloaded yourself.` |

### 5.3.1 Why the prose is a template, not a string

The classic drift in a document like this is the manifest saying 7.12 GB while a hand-written sentence says "about 8 GB", and nobody noticing for a year. Interpolating every number from `ModelTier` makes that impossible by construction rather than by review.

Where the copy lives: prose templates in a new `Sources/LDAUI/ModelCopy.swift`; numbers in `Models.json`. A unit test renders every tier's annotation and asserts that each interpolated value equals the manifest's (MM-15).

The three benchmark-derived quality figures (`criticalFound`, `criticalTotal`, `falseFlagOneIn`) come from `bench/results/scores-full.json` by the derivation already recorded in tiers PRD section 3.1. If the benchmark is re-run they are regenerated, not edited.

### 5.4 Where "Use another model" lives

Unchanged in substance from tiers PRD 2.4, with one placement change now that a real manager exists.

- The **Choose File...** control moves out of the AI tab body and into the Manage Models sheet as the last row, below a divider, visually separated from the tier list.
- It is **not** affected by Offline mode, the memory gate, or download state. It involves no connection and the app knows nothing about the file's footprint, so it has nothing to gate on.
- Choosing one still mints a security-scoped bookmark through `AISettings.setCustomModel(url:)` and still shows the Custom model rung in the ladder. Unchanged.
- A custom model is never stored in `Application Support/LDA/Models/`. It stays where the user put it, referenced by bookmark. Two reasons: copying a file the user did not ask us to copy is presumptuous at 13 GB, and the tier store is the app's inventory, which a custom file is not part of.
- The sheet's disk usage footer counts only the tier store, so a custom model does not appear in a number the Remove buttons cannot affect.

**Add a downloaded file** is a separate control, per tier row, shown in an overflow menu rather than as a primary button. It is the manual path from tiers PRD 4.3, preserved for offline installs and IT staging: it opens `NSOpenPanel`, runs the same verification, and copies into the tier store. It is the primary path only when Offline mode is on.

---

## 6. Download: the state machine

### 6.1 States

```
public enum ModelInstallState: Equatable, Sendable {
    case hidden                                          // manifest incomplete
    case builtIn                                         // ships in the app bundle
    case blockedByMemory(needsGB: Double, budgetGB: Double)
    case notInstalled
    case preflighting
    case downloading(written: Int64, total: Int64, bytesPerSecond: Double)
    case paused(written: Int64, total: Int64)
    case verifying(fraction: Double)
    case installed(verifiedAt: Date)
    case installedUnverified
    case failed(ModelInstallFailure)
}
```

`ModelInstallStore` holds `[tierID: ModelInstallState]` and rebuilds it from disk at launch. State is derived from the filesystem, never only from memory, so a crash mid-transfer resolves correctly on the next launch.

On-disk layout under `Application Support/LDA/Models/<tierID>/`:

| File | Meaning |
|---|---|
| `<fileName>` | the installed model |
| `<fileName>.partial` | bytes received so far |
| `download.json` | `{ expectedSize, expectedSHA256, bytesWritten, startedAt, sourceURL }` |
| `verified.json` | `{ sha256, verifiedAt, sizeBytes }` written only after a passing check |

`verified.json` is what lets the sheet say "Verified 29 Aug 2026" without rehashing 13 GB every time Settings opens. It is a cache of a proof, not the proof: it is written only after a real check, and is discarded whenever the model file's size or modification date does not match what it records.

### 6.2 Happy path

1. **Guard.** `canDownload(tier)` (section 8.3) must be true. If not, there is no control to press.
2. **Preflight.** All of these before a single byte, and before any UI beyond a spinner:
   - Offline mode off.
   - `URL(string: tier.sourceURL)` parses, scheme is `https`, host passes the allowlist.
   - Free space on the container volume, via `URLResourceValues.volumeAvailableCapacityForImportantUsage`, is at least `sizeBytes + 2 GB`. The margin covers the verification pass and normal system churn. Note this is a **direct download**, not the import-by-copy path, so space is needed once, not twice; the tiers PRD `fileSize + 2 GB` rule is retained but its rationale changes.
   - The destination directory can be created.
3. **Transfer.** `URLSessionDownloadTask` on an ephemeral configuration, with a delegate for progress and redirect checking. Bytes stream to `<fileName>.partial`. `download.json` is written at start and its `bytesWritten` updated at most once a second (not per callback; a 13 GB download would otherwise write tens of thousands of times).
4. **Hash.** SHA-256 accumulates over the stream via `CryptoKit.SHA256` (already a dependency, used by `EncryptedContainer`), so hashing costs no additional I/O. See 6.6 for the resume exception.
5. **Verify.** Section 6.5.
6. **Install.** Atomically rename `<fileName>.partial` to `<fileName>`, write `verified.json`, delete `download.json`.
7. **Report.** The row flips to Installed. The ladder rung becomes selectable. **The app does not auto-select it**: the user asked for a file, not for a change to how their documents are processed. The row offers `[ Use Balanced ]` as an explicit next step.

Step 7 deserves emphasis. Silently switching the detection setting because a download finished would change the redaction behaviour of the next document without the user deciding to. The tiers PRD non-goal "no automatic tier switching" covers this and it is easy to violate here in the name of convenience.

### 6.3 Transition table

| From | Event | To | Side effect |
|---|---|---|---|
| `notInstalled` | Download pressed | `preflighting` | none |
| `preflighting` | all checks pass | `downloading` | create dir, write `download.json` |
| `preflighting` | any check fails | `failed(...)` | nothing written |
| `downloading` | progress | `downloading` | update bar; persist `bytesWritten` at most 1/s |
| `downloading` | Cancel | `notInstalled` | delete `.partial` and `download.json` |
| `downloading` | connection lost | `paused` | keep `.partial` and `download.json` |
| `downloading` | disk full | `failed(.diskFull)` | keep `.partial`; offer Discard |
| `downloading` | app quits | (persisted) `paused` | `.partial` and `download.json` survive |
| `downloading` | bytes complete | `verifying` | close stream |
| `paused` | Resume | `downloading` | `Range: bytes=<written>-` |
| `paused` | Discard | `notInstalled` | delete `.partial` and `download.json` |
| `verifying` | all layers pass | `installed(verifiedAt: now)` | rename, write `verified.json` |
| `verifying` | hash or size mismatch | `failed(.contentMismatch)` | **delete `.partial`** |
| `verifying` | GGUF will not open | `failed(.unreadable)` | keep `.partial`, offer Discard |
| `installed` | Remove confirmed | `notInstalled` | delete file, demote if in use (section 7) |
| `installed` | file vanished externally | `notInstalled` | rebuild at launch; report per tiers PRD E2 |
| any | Offline mode turned on | unchanged | controls disable; a running download **continues** |
| `blockedByMemory` | (no event) | terminal | no control exists |

Two notes on that table.

**A hash mismatch deletes; an unreadable file does not.** A mismatch means we know the bytes are wrong, so keeping them is keeping garbage. An unreadable-but-hash-matching file means our manifest or our llama.cpp build is wrong, not the user's download, and deleting 13 GB of correct bytes to punish our own bug is the wrong trade. Offer Discard and let them decide.

**Turning on Offline mode does not kill a running download.** It gates starting one. Killing a transfer in flight because a setting changed would discard up to half an hour of work with no confirmation. The row says so: "Offline mode is on. This download will finish, and no new ones will start."

### 6.4 Failure branches

Every branch has a `ModelInstallFailure` case, a message, and a recovery action. Messages name the thing that happened; none of them say "an error occurred".

| # | Condition | State | Message | Actions |
|---|---|---|---|---|
| D1 | No route to host, DNS failure | `failed(.noConnection)` | "LDA could not reach huggingface.co. Check this Mac's internet connection and try again." | Try again |
| D2 | Connection drops mid-transfer | `paused` | "The connection was lost after {written} of {total}. What downloaded so far is kept, so resuming does not start over." | Resume, Discard |
| D3 | HTTP 404 | `failed(.notFoundUpstream)` | "The Balanced model is no longer at the address LDA has for it. You can download it yourself and add it with Add a downloaded file. The file name is gemma-4-12b-it-Q4_K_M.gguf." | Copy file name, Add a downloaded file |
| D4 | HTTP 401 or 403 | `failed(.accessDenied)` | "The server refused the request for this model. It may now require an account. You can download it in a browser and add it here." | Copy link, Add a downloaded file |
| D5 | Redirect leaves the allowlist | `failed(.redirectRefused(host:))` | "The download was redirected to {host}, which LDA is not allowed to contact, so it stopped. Nothing was downloaded." | Report, Add a downloaded file |
| D6 | `Content-Length` disagrees with the manifest | `failed(.sizeAnnouncedMismatch)` | "The file on the server is {n} GB, not the {m} GB LDA expects for Balanced. LDA stopped before downloading it." | Try again, Add a downloaded file |
| D7 | Free space below `sizeBytes + 2 GB` at preflight | `failed(.insufficientSpace)` | "Balanced needs 7.12 GB and there is 3.1 GB free on this disk. Free some space and try again." | Try again |
| D8 | Disk fills during the transfer | `failed(.diskFull)` | "The disk filled up after {written} of {total}. Free some space, then resume." | Resume, Discard |
| D9 | User cancels | `notInstalled` | none; the row returns to idle | Download |
| D10 | App quits mid-transfer | `paused` (on next launch) | "Paused at {written} of {total}." | Resume, Discard |
| D11 | SHA-256 mismatch at completion | `failed(.contentMismatch)` | "The file that arrived is not the Balanced model we published. It may have downloaded incompletely, or the copy on the server may have changed. The file was deleted and nothing was installed." | Try again |
| D12 | Final size mismatch | folded into D11 | same | Try again |
| D13 | Hash matches but `vocab_only` load fails | `failed(.unreadable)` | "The file downloaded correctly but this version of LDA cannot open it. Nothing was installed." | Discard, Try again |
| D14 | Offline mode on | control disabled, no failure state | "Offline mode is on, so LDA will not download. You can still add a file you downloaded yourself." | Add a downloaded file |
| D15 | Mac sleeps | `downloading` continues or drops to `paused` per D2 | see D2 | Resume |
| D16 | Destination directory cannot be created | `failed(.storeUnavailable)` | "LDA could not create its model folder. Restart the app and try again." | Try again |
| D17 | A second download is requested while one runs | request queued | "Waiting for Balanced to finish." | Cancel |
| D18 | TLS failure behind an inspecting proxy | `failed(.secureConnectionFailed)` | "The secure connection to huggingface.co could not be established. If your organization inspects network traffic, ask IT whether huggingface.co is allowed." | Try again, Add a downloaded file |

D3, D4, D6, and D18 all route to the manual path, because in each of those the network is not going to start working for this user and the browser is the answer. That is the payoff for keeping tiers PRD 4.3's flow rather than deleting it.

D17: one transfer at a time, queued rather than parallel. Two concurrent multi-gigabyte downloads on a firm's link is antisocial, and the progress display and the free-space precheck both become wrong when two transfers race for the same volume.

### 6.5 Verification: which layer runs, and when

Tiers PRD 4.5 defines three layers. Their roles differ on the download path from the import path, and conflating them is how a redundant check gets dropped or a necessary one gets skipped.

| Layer | Import path (user chose a file) | Download path (LDA fetched it) |
|---|---|---|
| **1. Byte count** | First and cheapest. Catches a truncated file instantly. | Runs **twice**. Once against `Content-Length` at preflight, before a byte is written, so a wrong file costs zero bandwidth (D6). Once against the finished `.partial`. |
| **2. GGUF header** | **Load-bearing for identity.** The user's file has no expected hash to compare against when it is a legitimate different build, so the header is what says "this is the gemma-4-12b family". Decides Verified / Recognised / Unrecognised. | **Not an identity check.** A matching SHA-256 already pins the exact bytes, so the header can add nothing about identity. It runs instead as a **loadability check**: a `vocab_only` open proving this llama.cpp build can read the file, so a first detection run does not fail 40 minutes after the download did. Failure is D13, a distinct state, never conflated with a mismatch. |
| **3. SHA-256** | Computed during the copy, free, because the bytes are already streaming. | Computed during the transfer, free, same reason. **This is the authority on the download path** and the reason certificate pinning is unnecessary (2.7). One exception in 6.6. |

Ordering on the download path: **1 (announced), then transfer, then 1 (actual), then 3, then 2, then install**. Hash before loadability, because a hash mismatch means delete and a loadability failure means keep, and running them the other way would burn a `vocab_only` load on bytes we are about to throw away.

A tier installed through a path where layer 3 could not run (an old manifest with an empty `sha256`, which section 4.2 now prevents at build time) is `installedUnverified` and says so in the row. It is never silently promoted to Verified.

### 6.6 Resume, and the conflict it creates with streamed hashing

Resume matters: 13.15 GB on the benchmark link is about half an hour, and losing that to a closed lid is the kind of thing users do not forgive twice. HTTP Range is well supported by the upstream CDN.

**The conflict.** A streamed SHA-256 cannot be resumed across a process restart. `CryptoKit.SHA256` exposes no way to serialise and restore its internal state, and there is no supported way to get it.

**Resolution, and it must be written down or someone will build the wrong thing:**

- **Uninterrupted download**: hash streams alongside the bytes. Free. `verifying` goes straight to the comparison and its progress bar jumps to 100 percent immediately.
- **Resumed download** (any transfer that spanned a pause): discard the partial hash state and compute the SHA-256 in a **separate full pass** over the completed file after the last byte arrives. At SSD read speed this is roughly 10 to 25 seconds for the largest tier. This is why `verifying` carries a `fraction` and shows a real progress bar with "Checking the file", rather than being an instant step.
- `download.json` carries a `wasResumed: Bool` so the store knows which path to take after a relaunch.

**Range request integrity.** A resumed request must send `If-Range` with the ETag captured on the first response where one is available. Without it, a file that changed upstream between the pause and the resume yields a spliced file: half the old model, half the new. The SHA-256 would catch it, but only after downloading the rest, and the user would see a mismatch they cannot explain. With `If-Range`, the server returns `200` and the whole file instead of `206`, and the client restarts cleanly. Record the ETag in `download.json`.

### 6.7 Concurrency and cancellation

- One transfer at a time (D17).
- `ModelInstallStore` is `@MainActor`. `ModelDownloader` does its work off the main actor and publishes progress back, coalesced to at most 10 updates a second so a 13 GB transfer does not saturate the main thread with view invalidations.
- Cancel is immediate and real: cancel the task, close the stream, unlink `.partial`, remove `download.json`. Verified by MM-27 asserting the directory is empty afterwards, the same shape as the existing tiers PRD AC-20.
- A download in flight does not block detection, review, export, or restore. It is not modal to anything.

---

## 7. Removal

### 7.1 What Remove does

1. Confirm (7.2), with the destination setting named in the confirmation.
2. Delete `<fileName>`, `verified.json`, and any stale `.partial` or `download.json` in that tier's directory.
3. Remove the now-empty `<tierID>` directory.
4. If the removed tier was the selected level, demote (7.3).
5. Report: "Removed Balanced. 7.12 GB is free again." with the sheet's disk footer updated.

The reported number is the file's actual size on disk read before deletion, not the manifest `sizeBytes`, so a Recognised different build reports what it actually reclaimed.

### 7.2 Removing the model in use

**Decision: allowed, behind a confirmation that states the consequence before the click.**

Rejected: refusing until the user switches first. It looks safer and is worse. It forces a two-step dance to protect an invariant we can maintain ourselves, and it produces a genuine dead end when the tier in use is the only one installed: the user cannot switch to anything meaningful and cannot delete either. Someone deleting a 13 GB file is usually doing it because they need the space now, and a tool that argues with them at that moment gets worked around.

What makes it safe is not refusal, it is **naming the outcome before it happens**. The confirmation computes the demotion target and puts it in the button: `Remove and switch`, with the target named in the body. The user is never surprised about what their next scan will do.

The Patterns only case gets stronger wording and a differently labelled button (`Remove and stop finding names`), because it is the only case that changes *what gets redacted* rather than *how well*. That state is only reachable if the bundled Quick model is somehow unavailable, which makes it rare and worth shouting about.

### 7.3 The demotion rule

One function, three callers, so the launch fallback and the removal demotion cannot drift apart:

```
AISettings.bestAvailableLevel(
    catalog: ModelCatalog,
    installedGB: Double,
    fileManager: FileManager
) -> DetectionLevel
```

Returns the **highest** rung in `DetectionLevel.modelLevels` that satisfies both:

- `MemoryGate.availability(for:installedGB:).isSelectable`, and
- `ModelCatalog.isInstalled(tier) || ModelCatalog.isBundled(tier)`

and `.patternsOnly` when none qualify.

Callers:

1. Post-removal demotion (this section).
2. Launch fallback when the stored level fails the gate (tiers PRD E6).
3. Launch recovery when the stored level's file has vanished (tiers PRD E2).

Rules the function encodes and the UI must not second-guess:

- **Never demote to a rung the machine cannot run.** Obvious, and easy to get wrong by demoting to "the next one down" positionally.
- **Never demote sideways to a rung with no file.** A rung with no file resolves to nil and produces the requested-but-unavailable report, which is correct behaviour but an avoidable outcome at a moment when we know the answer.
- **Demote downward only.** Removing Balanced on a machine where Most thorough is also installed demotes to Quick, not up to Most thorough. Removing a model is not consent to a slower one; "highest available" is bounded above by the level being removed.

That last rule means the signature needs the level being removed as an upper bound. Give `bestAvailableLevel` an optional `notAbove: DetectionLevel?` parameter, nil at launch (where any available rung is fine) and set to the removed level on removal.

### 7.4 Quick cannot be removed, and the duplicate-copy case

**Quick is bundled and has no Remove control.** Its bytes are inside the signed `.app`, the sandbox cannot write there, and deleting from a signed bundle would break the signature and Gatekeeper. The row says so plainly: "Built in and verified. Part of the app, so it cannot be removed." Its size is reported as "2.74 GB, inside the app" and is **excluded** from the sheet's reclaimable disk footer, because a number next to a Remove button that cannot act on it is a lie.

**The duplicate-copy case is real and must be handled.** This branch previously shipped the Appendix N direction, in which no model was bundled and Quick was downloaded into `Application Support/LDA/Models/quick/`. A user who upgrades from such a build has Quick in **both** places, wasting 2.74 GB, with the container copy shadowing the bundle in `resolveModelPath`.

Required behaviour:

- The Quick row detects the container copy and offers: **"A downloaded copy of Quick is also on this Mac. It is not needed because Quick is built into the app. [ Remove downloaded copy, 2.74 GB ]"**
- Removing it is safe: the bundle copy takes over via the existing fallback in `resolveModelPath`, with no change to the selected level and no reprocessing.
- **Refine the resolution order**: prefer the container copy only when it is `installed` *and* verified or at least the right size. A container copy that fails the size check must not shadow a good bundled copy. Today `isInstalled` already compares size, so this holds; add the test rather than assuming it stays true (MM-38).

### 7.5 Removal while a run is in flight

`LLMEngine` is constructed per run as a local value inside `ReviewModelDetection.llmSpans` (`Sources/LDAUI/ReviewModelDetection.swift:183`) and freed in `deinit`, so no long-lived handle exists between runs. The exposure window is only the duration of a detection or fill.

**Remove is disabled while `ReviewModel.status == .detecting` or a fill run is active**, with the reason: "Finish or stop the current scan first."

The reason is not crash safety. Unlinking a file that llama.cpp has `mmap`ed is legal on macOS and the running scan would finish normally, because the inode survives until the last descriptor closes. The reason is **the disk does not actually come back until the mapping is released**, so the app would report "7.12 GB is free again" while the volume's free space had not moved. Reporting a reclaim that has not happened, in a tool whose entire premise is telling the truth about what it did, is the wrong kind of small lie.

---

## 8. Can a memory-blocked model be downloaded?

### 8.1 Decision

**No. A tier that fails `MemoryGate` offers no download control of any kind.** No button, no overflow menu item, no drag-and-drop target, no keyboard route, and no `Add a downloaded file` for that tier either.

### 8.2 Reasoning

**1. On Apple Silicon the verdict is permanent.** Memory is on-package and cannot be upgraded. A 16 GB Mac will never become a 24 GB Mac. This is the argument that decides it: on a machine with upgradeable RAM, "download now, run after the upgrade" is a real user story and blocking would be paternalistic. Here, a blocked tier is blocked for the life of the machine, and the file would be inert forever.

**2. The ladder would refuse to select it anyway.** Tiers PRD 5.3 and AC-31 make a blocked rung non-selectable regardless of whether its file is present. So allowing the download produces a 13 GB file that the app will not use, which is the definition of the disappointment that rule exists to prevent.

**3. The costs are real and asymmetric.** 7.12 GB or 13.15 GB against an SSD that is often 256 or 512 GB on a 16 GB configuration, plus 20 to 50 minutes of a firm's shared link. The benefit is zero, not small.

**4. The expert escape hatch already exists, and it is not the download manager.** The person who genuinely wants to run Balanced on a 16 GB Mac and accept the swapping is a developer or an IT engineer. They have `lda anonymize --model <path>` and the MCP `modelPath` argument, both explicitly ungated by tiers PRD 5.4, and they have **Use another model** in the sheet, which is also ungated. None of those routes is closed by this decision. What is closed is the one route that a non-expert can walk into by accident.

**On the false-negative risk.** The gate assumes a roughly 9 GB office working set, so a lean 16 GB Mac running nothing but LDA might in fact manage Balanced at its 8.48 GB production peak. This is a real limitation of a static budget and it is accepted here, for two reasons: a heuristic that fails toward "you cannot" is the correct direction for a tool that must not stall mid-document on privileged work, and the expert who knows their machine has three ungated routes. Revisit only with evidence from real machines, not from an argument.

### 8.3 The single-gate invariant

Every download affordance derives from **one** computed property. Not three checks in three views.

```
extension ModelInstallStore {
    func canDownload(_ tier: ModelTier) -> Bool {
        ModelCatalog.isComplete(tier)
            && !ModelCatalog.isBundled(tier)
            && !isInstalled(tier)
            && MemoryGate.availability(for: tier, installedGB: installedGB).isSelectable
            && !isOfflineMode
            && !isDownloading(tier)
    }
}
```

The button, the menu item, the drop target, and the keyboard action all read this one property. This app has a documented history of multi-entry actions where one path was gated and another was not; the rule is to fix the gate, not the button. A unit test enumerates every tier at 8, 16, 18, 24, 32, and 64 GB and asserts the property matches the expected matrix (MM-31).

### 8.4 What the blocked row says

```
|  Balanced   gemma-4-12b                                                       |
|  [full annotation, unchanged]                                                 |
|  7.12 GB download   ~8.5 GB of memory   ~2 min 15 sec a contract              |
|  Needs a Mac with 24 GB of memory. This Mac has 16 GB.                        |
|  Cannot run on this Mac, so it is not offered for download.                   |
```

Copy rules, inherited from tiers PRD 5.3 and still binding:

- The annotation stays in full. The user should be able to read what they are not getting; that is what makes the requirement line informative rather than arbitrary.
- Requirement then fact, one sentence: "Needs a Mac with 24 GB of memory. This Mac has 16 GB."
- Never "unsupported", never "your Mac is too old", never an apology. The Mac is fine; the model is large.
- The tooltip carries the consequence: "Running a model this large with 16 GB of memory would slow the whole Mac down or stop partway through a document."
- **Do not** add "but you can use the command line". Advertising a bypass in the main UI turns a considered limit into a dare. The people who need it already know.

---

## 9. States and edge cases

Continues the tiers PRD E-series. E1 through E14 there remain in force.

| # | Condition | Behaviour | User sees | Recovery |
|---|---|---|---|---|
| M1 | Fresh install, 16 GB Mac, never connected | Quick from the bundle, fully functional | Ladder with Quick selected; the other two blocked | none needed |
| M2 | Fresh install, 32 GB Mac | Quick from the bundle | Balanced and Most thorough offer Download with sizes | Download |
| M3 | Upgrade from a build that downloaded Quick into the container | Container copy wins, identical bytes, no behaviour change | Quick row offers "Remove downloaded copy, 2.74 GB" | Remove it |
| M4 | Upgrade where the container Quick copy is corrupt | `isInstalled` size check fails, bundle copy takes over | Nothing unusual; the stale copy is offered for removal | Remove it |
| M5 | Download completes while Settings is closed | Installs and verifies normally | Row shows Installed on next open; no auto-selection | Select it |
| M6 | Download running, user quits the app | `.partial` and `download.json` survive | Next launch: "Paused at 3.9 of 7.12 GB" | Resume, Discard |
| M7 | Download running, Mac sleeps and wakes | Continues, or D2 | Progress resumes or Paused | Resume |
| M8 | Offline mode turned on mid-download | The transfer finishes; no new ones start | "Offline mode is on. This download will finish, and no new ones will start." | none |
| M9 | Offline mode forced by a configuration profile | Toggle disabled and on | "Set by your organization" | contact IT |
| M10 | Manifest URL is dead (D3) | No download possible for that tier | Message names the file and offers the manual path | Add a downloaded file |
| M11 | `Models.json` has an empty `sha256` for a tier | Tier hidden entirely | The tier does not appear anywhere | ship a fixed build |
| M12 | Verified installed file is deleted from the container by hand | Detected at launch; state rebuilt to `notInstalled`; demotion per 7.3 | tiers PRD E2 danger banner naming the tier | Download again |
| M13 | Remove pressed during a scan | Refused | "Finish or stop the current scan first." | stop or wait |
| M14 | Remove the tier in use, another installed one qualifies | Demotes to the highest qualifying rung at or below it | Confirmation names it before the click | none needed |
| M15 | Remove the tier in use, nothing else installed, Quick bundled | Demotes to Quick | Confirmation names Quick | none needed |
| M16 | Remove the tier in use, nothing installed, no bundle | Demotes to Patterns only | Strong confirmation and a differently labelled button | Download something |
| M17 | Disk fills mid-download (D8) | Paused, `.partial` kept | Names both numbers | free space, Resume |
| M18 | Two downloads requested | Second queued | "Waiting for Balanced to finish." | Cancel either |
| M19 | Upstream redirects off the allowlist (D5) | Refused, nothing written | Names the refused host | Add a downloaded file |
| M20 | Firm's TLS proxy breaks the handshake (D18) | Refused | Names the likely cause and the IT question | Add a downloaded file |
| M21 | File matches the hash but will not open (D13) | Not installed, `.partial` kept | Distinct message from a mismatch | Discard, Try again |
| M22 | User adds a downloaded file manually while Offline mode is on | Works normally | Nothing unusual | none needed |
| M23 | RAM-blocked tier, user tries every route | No route exists | Requirement line only | none |

---

## 10. Acceptance criteria

Executable without reading the rest of this document. "The 16 GB Mac" and "the 24 GB Mac" mean physical machines or VMs with that installed RAM. Numbered `MM-` to avoid collision with the tiers PRD's `AC-` series, which remains in force.

### Network promise and its verification

- **MM-1** `codesign -d --entitlements - LDA.app` shows `com.apple.security.network.client` present and `com.apple.security.network.server` absent.
- **MM-2** With a network monitor running, open the app, load a document, scan, review, export, restore, and quit, without pressing Download. Zero connection attempts.
- **MM-3** Press Download with the monitor running. Every connection resolves to a host ending in `huggingface.co` or `hf.co`. Record the full host list and confirm each appears in `packaging/README.md`.
- **MM-4** `grep -rn "no network access at all" Sources/ packaging/` returns nothing.
- **MM-5** `grep -rln "URLSession\|NWConnection\|CFReadStream\|NSWorkspace.open" Sources/` returns exactly one path: `Sources/LDAUI/ModelDownloader.swift`. This runs in CI and fails the build otherwise.
- **MM-6** Ten minutes after a download completes, the monitor shows no further connections.
- **MM-7** The standard network statement in section 2.2 appears verbatim in the AI tab and in the Manage Models sheet header. Diff the two strings in a unit test.
- **MM-8** Point the manifest's `sourceURL` at a host outside the allowlist in a test build. The download is refused at preflight and no `.partial` is created.
- **MM-8a** Simulate a redirect to a non-allowlisted host with a local stub. The transfer stops, D5 is shown, the message names the host, and nothing is written.

### Bundling

- **MM-9** On a packaged build, `Settings > AI` shows Quick as selectable with the "Built in" badge, on a machine with an empty `Application Support/LDA/Models/`. (This is the regression test for the stale `AITab.rungRow` logic in section 3.)
- **MM-10** `LDA.app/Contents/Resources` contains exactly one `.gguf`, named `Qwen3.5-4B-Q4_K_M.gguf`.
- **MM-11** With the network cable pulled and no models ever downloaded, load a document, scan, and confirm at least one PERSON or COMPANY span on `bench/fulldocs/full-en-agreement.json`.
- **MM-12** The Quick row has no Remove control in any state.

### Manifest

- **MM-13** A unit test asserts `ModelCatalog.isComplete(tier)` for every row in the shipped `Models.json`. **This test fails against the current file and must pass before release.**
- **MM-14** A unit test asserts `runtimeRSSGB < peakRSSGB` for every tier.
- **MM-15** A unit test renders every annotation and asserts each interpolated number equals the manifest value it came from.
- **MM-16** `package-app.sh` exits non-zero when any tier row fails completeness. Verify by blanking one `sha256` and running it.
- **MM-17** Blank one tier's `sha256` at runtime: that tier is absent from both the ladder and the sheet, and the other two are unaffected.
- **MM-18** Every `sourceURL` in the shipped manifest returns HTTP 200 with a `Content-Length` equal to that row's `sizeBytes`. Run as a release checklist step, not in CI, since CI must not depend on the network.

### Download, happy path

- **MM-19** On the 32 GB Mac, press Download on Balanced. It completes, verifies, and the row shows "Verified {today}".
- **MM-20** After MM-19, `Application Support/LDA/Models/balanced/gemma-4-12b-it-Q4_K_M.gguf` exists with exactly the manifest `sizeBytes`, and `shasum -a 256` on it equals the manifest `sha256`.
- **MM-21** After MM-19, the Balanced rung is selectable but **not selected**. The active detection level is unchanged from before the download.
- **MM-22** During MM-19, close the sheet, close Settings, and reopen. Progress continued and reflects real elapsed bytes.
- **MM-23** During MM-19, the AI tab's Balanced row shows an inline progress bar.
- **MM-24** During MM-19, load a document and run a scan on Quick. It completes normally and is not blocked by the transfer.
- **MM-25** The progress display shows bytes written, total, an observed rate, and an ETA. The ETA is computed from observed throughput, not from any manifest constant.

### Download, failures

- **MM-26** Disconnect the network mid-download. The row goes to Paused, names the byte counts, and offers Resume and Discard.
- **MM-27** Press Cancel mid-download. `Application Support/LDA/Models/balanced/` is empty or absent. No `.partial`, no `download.json`.
- **MM-28** Quit the app mid-download, relaunch, open Settings. The row shows Paused with the correct byte count. Resume completes the file, and MM-20's checks pass on it.
- **MM-29** Serve a corrupted file from a local stub whose `Content-Length` matches. The download completes, verification fails, the file is **deleted**, and the message is the D11 wording.
- **MM-30** Serve a file whose `Content-Length` disagrees with the manifest. The download is refused before any byte is written (check that no `.partial` was created).
- **MM-30a** Fill the disk to below `sizeBytes + 2 GB` and press Download. Refused at preflight, with both numbers in the message, before any panel or transfer.
- **MM-30b** Request a second download while one runs. It queues rather than running in parallel, and the row says so.

### Memory gate and downloads

- **MM-31** A unit test enumerates every tier at 8, 16, 18, 24, 32, and 64 GB installed and asserts `canDownload` matches the expected matrix. At 16 GB and 18 GB, Balanced and Most thorough are false.
- **MM-32** On the 16 GB Mac, the Balanced and Most thorough rows show the full annotation, the requirement line, and "Cannot run on this Mac, so it is not offered for download." No Download button.
- **MM-33** On the 16 GB Mac, the blocked rows expose no download route through the overflow menu, keyboard, or drag and drop. Tab through the sheet and confirm focus skips every download affordance on those rows.
- **MM-34** On the 16 GB Mac, `lda anonymize --model <balanced gguf>` still runs. The gate does not reach the CLI.
- **MM-35** On the 16 GB Mac, **Use another model** still accepts any GGUF, including the Balanced file. It is not gated.

### Removal

- **MM-36** Remove an installed tier that is **not** in use. The file is gone, the sheet's disk footer drops by that amount, and the row returns to Not installed with a Download button.
- **MM-37** Remove the tier **in use** while another qualifying tier is installed. The confirmation names the destination setting before the click, and after confirming, the active level equals that destination.
- **MM-37a** Remove the tier in use when only bundled Quick remains. The confirmation names Quick; the active level becomes Quick; a scan afterwards runs the AI pass.
- **MM-37b** With no bundled model present (unbundled dev build), remove the only installed tier. The confirmation uses the Patterns only wording and the differently labelled button, and the active level becomes `.patternsOnly`.
- **MM-37c** Removing Balanced while Most thorough is also installed demotes to Quick, not to Most thorough. (The `notAbove` bound in section 7.3.)
- **MM-38** Place a truncated `Qwen3.5-4B-Q4_K_M.gguf` in `Models/quick/` on a bundled build. The bundled copy is used, detection runs, and the row offers to remove the stale downloaded copy.
- **MM-39** Start a scan, then attempt Remove. It is disabled with "Finish or stop the current scan first." Stop the scan; Remove becomes available.
- **MM-40** After any removal, the reported reclaimed figure equals the file's actual on-disk size before deletion. Verify against `df` on the container volume with no other writes in flight.

### Offline mode

- **MM-41** Turn on Offline mode. Every Download control is disabled with the stated reason. **Add a downloaded file** and **Use another model** stay enabled.
- **MM-42** With Offline mode on, install Balanced from a local file. It verifies and installs normally, and no connection is attempted (confirm with the monitor).
- **MM-43** Turn on Offline mode during a running download. The transfer finishes, and the row explains that no new downloads will start.
- **MM-44** Write `com.haotianyi.LDA.offlineMode = true` at the managed domain. The toggle is on, disabled, and reads "Set by your organization".
- **MM-45** With Offline mode on, `ModelDownloader` refuses to construct a task even when called directly. Assert by unit test, not only through the UI.

### Copy

- **MM-46** No digit sequence resembling a score (`0.847`, `95%`, `F1`, `precision`, `recall`) appears anywhere in the sheet or the AI tab.
- **MM-47** No em dash or en dash appears in any string added by this feature. Assert by CI grep over `Sources/`.
- **MM-48** Every model row shows, at minimum: what it is good and weak at, download size, memory used while running, time per contract, the Mac it needs, and its current state. Verify by reading each row against this list on a 16 GB and a 32 GB machine.
- **MM-49** The sheet footer stating the twelve document test set basis is present and visible without scrolling past the last row.
- **MM-50** Existing test suite passes with no skips.

---

## 11. The highest risk

**The riskiest link is not the download code. It is that the offline guarantee moves from something the operating system enforces to something we enforce, and that move is permanent and one-way.**

Concretely: before this release, a firm's security reviewer could open `LDA.entitlements`, see no network key, and be done. The kernel was the enforcement, and the check took five seconds and required no trust in us. After this release, the same reviewer must take our word for it, or audit the source, every release, forever.

Why this ranks above the empty `sha256` fields, which are the more obvious problem: **B1 is a checklist item and this is a structural change.** B1 gets fixed by running `shasum` three times and it is caught by MM-13 before anyone can ship past it. The entitlement change cannot be fixed. It can only be paid down, continuously, by discipline that no test fully captures.

The three specific ways it hurts:

1. **It removes the strongest sentence in the product's pitch.** "This app cannot connect to the internet" is a claim almost no legal-tech tool can make, and it was the reason a partner would run privileged documents through it. "It connects only when you ask it to, and only to one place" is a much weaker claim, and every buyer who has heard a vendor say something similar and been wrong will discount it.
2. **It makes every future feature a little easier to get wrong.** The kernel used to reject a well-meant `URLSession` call at runtime. Now it succeeds. A future engineer adding a font, a crash reporter, an update check, or a "check for a newer model" convenience will find nothing in their way. The section 2.5 chokepoint and the MM-5 CI grep exist entirely to restore that friction, and a CI grep is much weaker than a kernel.
3. **A single mistake is unrecoverable in reputation terms.** One outbound connection during a scan, found by one firm's monitor, and the claim is not repaired by an apology or a patch. The product's whole thesis is that you can trust it with the documents you cannot trust anything else with.

**What the mitigation actually is**, ranked by how much it buys:

- **MM-5, the CI grep, is the load-bearing one.** It converts "audit the codebase" into "run one command" and it runs on every commit, not every release. Treat a failure as a release blocker, never as something to add an exception to. If a second file ever legitimately needs network access, that is a product decision requiring this section to be rewritten, not an allowlist entry.
- **The published V1 through V5 checklist** in `packaging/README.md`. Handing a reviewer the tests, including the ones that would catch us, is what makes the claim credible when it can no longer be proved structurally.
- **Offline mode with a managed key.** The only thing in this spec that gives a firm back a switch they control.
- **MM-2 and MM-6**, which are cheap and should be run on every release build, not once.

**What I would do beyond this spec, if there is appetite**: split the downloader into a separate, sandboxed XPC helper that holds the network entitlement while the main app does not. Then the main app's entitlements are structurally clean again, the reviewer's five-second check works on the process that touches documents, and the helper is small enough to audit completely. It was not specified here because it is a meaningful amount of packaging, signing, and notarization work for a benefit that is entirely about verifiability rather than function. It is the right answer if a firm's security review ever blocks a deal, and it is worth knowing that the option exists before that conversation happens rather than during it.

---

## Action list

| # | Action | Owner | Window |
|---|---|---|---|
| 1 | Fill all three `sha256` values; confirm the Qwen3.8-27B `sourceURL` against the real artifact; capture the missing GGUF header fields; add `runtimeRSSGB`, `bundled`, and the annotation inputs (B1 through B6) | Engineering | **Before any UI work.** Blocks the feature. |
| 2 | Confirm the live HuggingFace CDN host families and publish them in the allowlist and in `packaging/README.md` (2.6) | Engineering | before the downloader is written |
| 3 | Add `com.apple.security.network.client` with a scoped comment; rewrite `packaging/README.md` "The offline guarantee"; update copy sites C1 through C8 | Engineering | first, independently reviewable |
| 4 | Fix `AITab.rungRow` so a bundled tier counts as installed (section 3, MM-9) | Engineering | P0, independent of everything else |
| 5 | `ModelDownloader` with allowlist, redirect checking, streamed SHA-256, resume, and the CI grep that keeps it alone | Engineering | after 2 and 3 |
| 6 | `ModelInstallStore` at app scope; Manage Models sheet; annotations as templates; inline progress in the AI tab | Engineering | after 5 |
| 7 | Removal with the shared `bestAvailableLevel` demotion, wired into the E2 and E6 paths as well | Engineering | with 6 |
| 8 | Offline mode, including the managed-preference path and the bottom-of-stack refusal | Engineering | with 6 |
| 9 | Run V1 through V5 on a signed, notarized build under a network monitor; record the host list | QA | before release |
| 10 | Publish the V1 through V5 checklist in `packaging/README.md` for firms' security reviews | Product | with 9 |

---

## Assumptions, open questions, and non-goals

**Assumptions**

- HuggingFace serves `Range` requests on model files and returns a stable `ETag`. If it does not, resume degrades to restart and section 6.6's second half is dead code. Verify in the spike for action 2.
- The upstream repositories stay available at the manifest URLs. A dead link is D3, which routes to the manual path, so it degrades rather than breaks. But an app update is the only real fix, and it will happen eventually.
- A firm's proxy, where one exists, allows `huggingface.co`. Many will not. D18's message is written to get the user to the right IT question quickly, and the manual path remains.
- The measured office working set of roughly 9 GB behind `MemoryGate` still holds. Unchanged from the tiers PRD and still the weakest input to the gate.
- The twelve document benchmark corpus generalises. It is a small sample; the tier ordering is stable across it but the exact fractions in the annotations are not precision instruments. The footer says so.

**Open questions**

- **Q4.** Should the XPC-helper split in section 11 be scheduled rather than merely known about? It is the only design that restores the structural guarantee. Decision belongs to whoever owns the first enterprise security review.
- **Q5.** Is `hf.co` sufficient as a CDN allowlist entry, or does the content host live outside it? Blocks action 2 and, if the answer is bad, changes what section 2.2's standard statement can honestly say.
- **Q6.** Should a completed download offer `[ Use Balanced ]` inline, or say nothing and let the user return to the ladder? This spec says offer it, as an explicit control and never as an automatic switch. Worth watching: if users routinely download and then forget to select, the friction is in the wrong place.
- **Q7.** Should the manifest carry a second mirror URL per tier so D3 has an in-app recovery? It doubles the allowlist surface and the verification story stays identical since the hash is unchanged. Deferred, not rejected.

**Non-goals, restated so nobody adds them back**

- No background downloads, no prefetch, no update check, no version ping.
- No telemetry, no crash reporting, no analytics.
- No mirror or proxy of our own.
- No automatic tier switching, including after a download completes.
- No download path in the CLI or MCP surfaces.
- No second file in `Sources/` that can open a connection.

---

## Appendix A: implementation map

| Change | File |
|---|---|
| **New.** The only type in the app that can open a connection. Allowlist, redirect delegate, streamed SHA-256, Range resume. | `Sources/LDAUI/ModelDownloader.swift` |
| **New.** App-scope `ObservableObject` owning per-tier state, the active task, and resume metadata. Survives sheet and window dismissal. | `Sources/LDAUI/ModelInstallStore.swift` |
| **New.** The Manage Models sheet. | `Sources/LDAUI/ManageModelsView.swift` |
| **New.** Annotation templates, interpolated from `ModelTier`. | `Sources/LDAUI/ModelCopy.swift` |
| `ModelTier` gains `runtimeRSSGB`, `bundled`, `criticalFound`, `criticalTotal`, `falseFlagOneIn`, `modelDisplayName`. `ModelCatalog` gains `isComplete(_:)`, `partialURL(for:)`, `installedSizeOnDisk(_:)`. `MemoryGate` gains `minimumInstalledGB(for:)`. | `Sources/LDAUI/ModelTiers.swift` |
| `offlineModeKey`; `bestAvailableLevel(catalog:installedGB:fileManager:notAbove:)`; refine `resolveModelPath` container-versus-bundle preference. | `Sources/LDAUI/AISettings.swift` |
| **Fix** `rungRow` to treat a bundled tier as installed. Add the Manage Models button, the inline download bar, the Offline mode row. Move `Choose File...` into the sheet. Replace the footer with the standard network statement. | `Sources/LDAUI/SettingsView.swift` |
| On-device badge `.help` text (C1). | `Sources/LDAUI/AppShell.swift` (around line 435) |
| Verify the network paragraph matches the long statement; correct the `modelAvailable` doc comment now that a model ships again. | `Sources/LDAUI/OnboardingView.swift` |
| `vocab_only` open for the loadability check (already planned by the tiers PRD). | `Sources/LDACore/Engine/GGUFMetadata.swift` |
| Add `com.apple.security.network.client` with a scoped comment; keep the `.network.server` prohibition explicit. | `packaging/LDA.entitlements` |
| Manifest completeness validation gate; keep the existing Quick bundling. | `packaging/package-app.sh` |
| Rewrite "The offline guarantee"; publish the V1 through V5 reviewer checklist and the host allowlist. | `packaging/README.md` |
| Fill `sha256`, confirm URLs, add the new fields. | `Sources/LDAUI/Resources/Models.json` |
| **New tests.** Manifest completeness, annotation interpolation, `canDownload` matrix, demotion including `notAbove`, offline refusal at the bottom of the stack, single-chokepoint grep. | `Tests/LDACoreTests/ModelManagementTests.swift` |

Unchanged by design: `Restorer`, `MappingStore`, `EncryptedContainer`, `SessionRecordStore`, `DeterministicEngine`, `LLMExtractor`, the placeholder scheme, and every CLI and MCP signature.

---

## Appendix B: measured data used in this document

Every user-facing number in this specification traces to one of these. Nothing is estimated or rounded up.

| Tier | Model | Download | Peak RSS (harness, gates) | Peak RSS (production, displayed) | Minimum Mac | Seconds per contract | F1 | Critical recall | Critical missed | Surface drift |
|---|---|---|---|---|---|---|---|---|---|---|
| Quick | Qwen3.5-4B Q4_K_M | 2.74 GB | 3.60 GB | 3.11 GB | 16 GB | 53 | 0.847 | 0.972 | 1 of 36 | 0 |
| Balanced | gemma-4-12b Q4_K_M | 7.12 GB | 9.21 GB | 8.48 GB | 24 GB | 135 | 0.954 | 0.972 | 1 of 36 | 0 |
| Most thorough | Qwen3.8-27B UD-Q3_K_XL | 13.15 GB | 13.83 GB | 12.16 GB | 24 GB | 265 | 0.903 | 1.000 | 0 | 0 |

Derived, and used only in the annotations:

| Tier | Precision | Dismiss rate as a fraction | Time as shown |
|---|---|---|---|
| Quick | 0.785 | about 1 in 5 | about 53 seconds |
| Balanced | 0.936 | about 1 in 15 | about 2 min 15 sec |
| Most thorough | 0.875 | about 1 in 8 | about 4 min 25 sec |

Sources: `bench/results/scores-full.json` for quality; the tiers PRD Appendix M for production memory; the tiers PRD section 3.1 for the precision derivation. "Critical" means PERSON, COMPANY, and ADDRESS, the three types `DeterministicEngine` has no backstop for.

---

---

## Appendix C: reconciliation with `ModelInstaller.swift`

An implementation landed in the worktree while this document was being written: `Sources/LDAUI/ModelInstaller.swift`, plus `Tests/LDACoreTests/ModelInstallerTests.swift`, and `com.apple.security.network.client` is already present in `packaging/LDA.entitlements`. This appendix reconciles the two so nobody builds a second downloader.

**Naming.** Where this document says `ModelDownloader` and `ModelInstallStore`, read `ModelInstaller`. Where it says `ModelInstallState`, read `ModelInstallPhase`. The existing single-type design is fine; the split in Appendix A was a suggestion, not a requirement. `ModelInstaller` is already `@MainActor` and `ObservableObject`, which satisfies section 5.1 provided it is created once at app scope in `LDAApp` and injected, rather than constructed inside `AITab`.

**Already satisfied. Do not rebuild:**

| Spec | Status in `ModelInstaller.swift` |
|---|---|
| 2.5 single chokepoint, with a comment explaining why | Done, and the header even names the audit grep. This is the strongest part of the file. |
| 6.2 step 2, https and non-empty host validation | Done, with a correct note that `URL(string:)` alone is not validation. |
| 6.2 step 2, free-space precheck before transfer | Done via `volumeAvailableCapacityForImportantUsage`. |
| 6.5 layer 1, byte count at completion | Done. |
| 6.5 layer 3, SHA-256, chunked so a 13 GB file is never resident | Done, and `sha256Hex(of:)` reads in 4 MB chunks. |
| Delete on mismatch rather than install | Done for both size and digest. |
| 7.1 removal reporting actual on-disk size, taking the empty directory with it | Done. |
| 7.4 bundled tiers can never be removed | Done, guarded inside `remove`. |
| No cookies, no cache, minimal request surface | Done. |

**Gaps against this specification, in severity order. These are the real work:**

| # | Gap | Spec | Why it matters |
|---|---|---|---|
| **G1** | **An empty `sha256` skips verification and installs anyway** (`if !tier.sha256.isEmpty`). | 4.2, 6.5 | All three manifest rows carry `""` today, so **every download currently installs unverified**, silently, with no state saying so. This is the single most important fix. Either hide the tier (4.2) or install as `installedUnverified` and label it. Never install silently unverified. |
| **G2** | No host allowlist. Any `https` host is accepted. | 2.6 | The published claim "connects only to huggingface.co" is enforced by nothing. A mistaken or edited manifest entry sends a user's machine anywhere. |
| **G3** | No `willPerformHTTPRedirection` delegate. | 2.6 | HuggingFace `resolve/` URLs always redirect to a CDN host. Without a per-hop check, G2 is unenforceable even if the allowlist is added, and V3 in the reviewer checklist would fail. |
| **G4** | `install` does not consult `MemoryGate`. | 8.3 | The download bar is currently gated only by whatever the view does. The invariant must hold at the bottom of the stack, or a future call site bypasses it. |
| **G5** | No offline-mode refusal. | 2.8 | Same reason as G4: the check belongs in `install`, not only in the button. |
| **G6** | No `Content-Length` preflight against the manifest. | 6.5, D6 | A wrong file upstream costs a full multi-gigabyte transfer before anyone notices. |
| **G7** | No resume, and no state persisted across relaunch. | 6.6, M6 | Cancel and quit both lose everything. At 13.15 GB that is roughly half an hour discarded with no confirmation. |
| **G8** | No GGUF loadability check after a passing hash. | 6.5 layer 2, D13 | A file that verifies but cannot be opened fails at the user's first scan instead of at install time. |
| **G9** | `remove` does not demote the selected level and does not refuse during a scan. | 7.3, 7.5 | Removing the tier in use leaves the selection pointing at a deleted file, and a reclaim figure reported while llama.cpp still holds the mapping is not true. |
| **G10** | Disk headroom is `sizeBytes + 1 GB`. | 6.2 | Spec requires 2 GB. The download lands in a temp file and is then moved, and verification reads it back, so 1 GB is thin on a nearly full volume. |
| **G11** | `URLSessionConfiguration.default` rather than `.ephemeral`. | 2.6 | Cache and cookies are already disabled individually, so this is cosmetic, but ephemeral makes the property structural instead of a list of opt-outs that a later edit can miss. |

**Sequencing change to the action list.** G1, G2, and G3 move ahead of everything else. Together they are the difference between the network claim in section 2.2 being enforced and being merely asserted, and section 11 argues that this distinction is the highest risk in the feature. Action list items 1 and 2 remain the prerequisites for all three.

---

> Prepared by Product. Engineering owns the sequencing inside each action item. The two decisions in section 2.1 and section 3 arrived settled and are not re-argued here; sections 2.4 through 2.8 exist to pay for the first one.
