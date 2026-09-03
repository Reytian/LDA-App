# LDA.app Model Tiers: Functional Specification

**Date**: 2026-08-29
**Type**: PRD / functional specification
**Owner**: Product
**Status**: Superseded in part by `model-management-prd.md`, and see the 2026-09-03 note below


> **Update, 2026-09-03.** This document's Appendix N position, that nothing is bundled, is
> the shipping design again. The app ships without a model; a fresh install downloads one
> or imports a checksum-verified file the user supplies. Statements below that Quick is
> "bundled with the app" describe the interim build only.

> This spec was written for a build with **no** network entitlement, so it
> routes model acquisition through a manual copy-the-link sheet and
> instructs engineering not to add `com.apple.security.network.client`.
> That decision was reversed: the app now has that one entitlement and an
> in-app model manager. Where the two specs disagree about the network,
> `model-management-prd.md` governs. The tier definitions, memory gate, and
> detection ladder below are still current.
**Applies to**: `macos/LDACore` (LDAUI, LDACore, LDAApp, packaging)

---

## TL;DR

- **Core goal**: let the end user choose how hard the app looks for names, companies, and addresses, on a single ladder, without ever being offered a rung their Mac cannot run.
- **Key decisions**: (1) merge `DetectionMode` and the model tiers into **one four rung control**, retiring the words "Fast" and "Thorough" from the tier vocabulary; (2) bundle **Quick only**, install the other two by **import by copy into the app container**, with the download link copied to the clipboard rather than opened; (3) **replace the bundled `lda-v2` fine tune with Qwen3.5-4B** as the built in default.
- **Blocking prerequisite**: the stored model path (`AISettings.customModelPathKey`) has no security scoped bookmark, so a user chosen model becomes unreadable after relaunch and the AI pass is skipped under an indicator that is indistinguishable from an intentional pattern only run. Fix this in the same release.

---

## Core decision card

| Item | Content |
|---|---|
| Recommended approach | One "How hard should LDA look?" ladder with four rungs. Quick is bundled. Balanced and Most thorough are user installed and copied into the app container. Memory gates rungs by installed RAM. |
| Priority | P0 for the ladder, the memory gate, the default model swap, and the bookmark and reporting fixes. P1 for the model manager sheet polish and per document time estimates. |
| Expected impact | Removes the single worst outcome in the product (a lawyer believing an AI pass ran when it did not), and lets 24 GB and 32 GB users buy accuracy with time. |
| Resource need | One engineer, roughly two weeks, plus a measurement pass on the benchmark Mac to fill the model manifest. |
| Risk level | Medium overall. High on one item: the published memory numbers were measured under the benchmark harness configuration, not under the production `LLMEngine.Config` defaults. |

---

## 1. Goals and non-goals

### 1.1 Goals

**G1. One decision, not two.** The user answers a single question, "how hard should LDA look for names?", and never has to reason about the interaction of two settings that share vocabulary.

**G2. Never offer what the machine cannot run.** A tier that would not fit in memory alongside a normal working set is visible, explained, and not selectable. The user learns why, rather than discovering it through a stall.

**G3. Honest, plain language quality claims.** No F1 scores in the interface. The user is told what changes for them: how long it takes, how much they will have to review, and how likely something is to be missed.

**G4. Getting a model must be possible without the app ever touching the network.** The absence of a network entitlement is the product. The acquisition flow is designed around that constraint, not in spite of it.

**G5. A chosen model keeps working across relaunches**, and when it does not, the user is told in words, in the window, not in a tooltip.

**G6. Ship the best 16 GB model we have.** The bundled default is chosen on measured evidence, not on sunk cost.

### 1.2 Non-goals

- **No in app download, ever.** Not behind a flag, not "just for the model", not through a helper tool. See section 4.1.
- **No automatic tier switching.** The app does not silently escalate to a heavier model because a document looks hard. The user's choice is the user's choice.
- **No per document tier override in v1.** The tier is an application setting. Per document override is a plausible v2 item, and it is out of scope here.
- **No model quality telemetry.** Nothing is measured, aggregated, or sent. There is nowhere to send it.
- **No first run hardware benchmark.** Time estimates come from a static manifest. Calibrating against the user's own Mac is a v2 item.
- **No change to the placeholder scheme, the mapping format, or the encrypted container.** The model affects detection only. Round trip compatibility across a model change is a requirement, not a feature (see section 6.3).
- **No gating of the CLI or MCP surfaces.** `lda anonymize --model` and the MCP `modelPath` argument stay unrestricted power user surfaces.

---

## 2. Information architecture decision

### 2.1 The conflict

Today there are two settings, and the new tiers want the same two words:

| Existing | Type | Values | Meaning |
|---|---|---|---|
| Detection mode | `DetectionMode` in `Sources/LDAUI/AISettings.swift` | `.thorough` / `.fast` | Whether the on device AI runs at all. Drives `ReviewModel.useLLM`. |
| Model | `AISettings.customModelPathKey` | free text GGUF path | Which local model runs. Surfaced in `SettingsView` `AITab` as "Choose Model..." plus "Use Bundled Model". |
| **Proposed tiers** | new | Fast / Balanced / Thorough | Which of three local models runs. |

Shipping both would put "Fast" in two controls with two unrelated meanings, and "Thorough" in two controls where one of them means "run the AI at all" and the other means "run the biggest AI". That is not a labelling problem that better copy can rescue. It is one axis wearing two hats.

### 2.2 Decision: merge into one ladder of four rungs

**These are the same axis.** Every one of the four options answers "how much work does the app do to find the entity types that patterns cannot catch, and what does that cost me in time and review?" `Patterns only` is simply the zeroth rung: zero work, zero wait, zero coverage of PERSON, COMPANY, and ADDRESS.

Introduce a new user facing enum in `AISettings.swift`:

```
public enum DetectionLevel: String, CaseIterable {
    case patternsOnly    // no LLM
    case quick           // Qwen3.5-4B Q4_K_M
    case balanced        // gemma-4-12b-it Q4_K_M
    case mostThorough    // Qwen3.8-27B UD-Q3_K_XL
}
```

`DetectionMode` is **not** kept as a second user facing setting. It becomes a derived internal value so that `ReviewModel.useLLM` and every existing call site keep working unchanged:

```
level.usesLLM  -> false for .patternsOnly, true otherwise
level.tierID   -> nil for .patternsOnly, otherwise the manifest tier id
```

`AISettings.apply(to:bundledDefault:defaults:)` keeps its signature and sets `model.useLLM = level.usesLLM` and `model.modelPath = resolvedPath(for: level)`.

**Migration of the stored value** (`AISettings.detectionModeKey`, raw values `"thorough"` and `"fast"`) is handled by a one time read at first launch after update:

| Stored `detectionMode` | Stored `customModelPath` | New `detectionLevel` |
|---|---|---|
| `fast` | anything | `patternsOnly` |
| `thorough` or unset | empty | `quick` |
| `thorough` | points at an installed tier model | that tier |
| `thorough` | points at any other readable GGUF | `custom` (see 2.4) |
| `thorough` | points at an `lda-v2-*.gguf` | `custom`, plus the one time notice in section 6.4 |

Write the new key `com.haotianyi.LDA.detectionLevel`. Leave `detectionModeKey` in place, unread, for one release so a downgrade does not lose the user's setting.

**Rejected alternative: two layers** ("Run on device AI: on/off" plus a three way model picker). It preserves the collision in a milder form, leaves a live but meaningless model picker whenever AI is off, and forces the user to hold two mental variables to answer one question. The only argument for it is that it maps more directly onto the code as it stands today, which is not a user's problem.

### 2.3 Naming

Do not reuse "Fast" or "Thorough" as tier names. Both words already carry the old meaning in shipped copy (`DetectionMode.label`), in `AITab`'s explanatory paragraph, and in whatever the user has already learned. Reusing them makes every old screenshot, note, and support answer wrong in a way that reads as correct.

| Internal | User facing name | Model |
|---|---|---|
| `.patternsOnly` | **Patterns only** | none |
| `.quick` | **Quick** | Qwen3.5-4B Q4_K_M |
| `.balanced` | **Balanced** | gemma-4-12b-it Q4_K_M |
| `.mostThorough` | **Most thorough** | Qwen3.8-27B UD-Q3_K_XL |

"Most thorough" rather than "Thorough" is deliberate: the superlative signals a ceiling, and it is different enough from the retired `DetectionMode.thorough` that no one confuses an old note with a new setting.

### 2.4 Where "bring your own model" goes

The free text GGUF path does not disappear, but it stops being a peer of the tiers. It moves into the **Manage Models** sheet as "Use another model", and when one is active the ladder shows a fifth, dynamically inserted rung labelled **Custom model** with the file name beneath it. A custom model carries no tier badge, no time estimate, and no memory verdict, because the app knows nothing about it. Selecting any of the four named rungs clears it.

Rationale: the developer, and any firm with its own fine tune, must be able to run an arbitrary local GGUF. Presenting it as an equal fifth option in the main ladder would imply the app can reason about it, which it cannot.

### 2.5 Final settings panel

Settings keeps its six tabs. The AI tab is rebuilt.

```
+----------------------------------------------------------------------+
|  General  | [AI] |  Vocabulary  |  Learned  |  Sharing  |  History    |
+----------------------------------------------------------------------+
|                                                                      |
|  How hard should LDA look?                                           |
|  Patterns always run. The options below decide whether the on device  |
|  AI also looks for names, companies, and addresses, and how deeply.   |
|                                                                      |
|  ( )  Patterns only                                        instant   |
|       Emails, phones, dates, amounts, and ID numbers.                |
|       Names, companies, and addresses are not found.                 |
|                                                                      |
|  (o)  Quick                             about 1 min per contract     |
|       Finds names, companies, and addresses. Built in.               |
|       Verified                                                       |
|                                                                      |
|  ( )  Balanced                          about 2 min per contract     |
|       Finds a little more than Quick and flags less that you have    |
|       to dismiss.                                                    |
|       Needs 24 GB of memory. This Mac has 16 GB.          [disabled] |
|                                                                      |
|  ( )  Most thorough                     about 4 min per contract     |
|       Missed nothing in our testing. Flags more for you to review.   |
|       Needs 24 GB of memory. This Mac has 16 GB.          [disabled] |
|                                                                      |
|  ...................................................................  |
|                                                                      |
|  Model files                                     [ Manage Models... ]|
|  Quick, built in. Balanced and Most thorough are not installed.      |
|                                                                      |
|  [lock icon] Every model runs fully on this Mac. The app has no      |
|              network access at all.                                  |
+----------------------------------------------------------------------+
```

A 32 GB Mac with nothing extra installed sees:

```
|  ( )  Balanced                          about 2 min per contract     |
|       Finds a little more than Quick and flags less that you have    |
|       to dismiss.                                                    |
|       Not installed.  8 GB download.               [ Get Balanced... ]|
```

The Manage Models sheet:

```
+----------------------------------------------------------------------+
|  Model files                                                    [x]  |
|                                                                      |
|  LDA has no network access, by design, so it cannot download models  |
|  for you. Download a model with your browser, then add it here.      |
|                                                                      |
|  Quick            Qwen3.5-4B                      2.74 GB   Built in |
|                   Verified                                           |
|                                                                      |
|  Balanced         gemma-4-12b-it                  7.12 GB            |
|                   Not installed             [ Copy download link ]   |
|                                             [ Add downloaded file... ]|
|                                                                      |
|  Most thorough    Qwen3.8-27B                    13.15 GB            |
|                   Installed, verified 2026-08-29    [ Remove ]       |
|                                                                      |
|  ...................................................................  |
|  Use another model                                                   |
|  Any local GGUF. LDA cannot tell you how well it will work or how    |
|  much memory it needs.                          [ Choose File... ]   |
|                                                                      |
|  Models are stored inside LDA's own folder on this Mac.              |
|  17.1 GB used. 214 GB free.                                          |
+----------------------------------------------------------------------+
```

---

## 3. User facing copy for the four rungs

Rules for this copy:

1. **No scores.** Never show F1, precision, recall, or any decimal. Translate into consequence.
2. **The ladder is monotonic in one thing only: how little it misses.** It is not monotonic in every measurement, and the copy must not imply that it is. Balanced actually produces the tidiest review queue of the three (highest precision as well as highest F1); Most thorough is the only tier that missed nothing at all, and it pays for that by flagging more. Say so plainly instead of pretending "bigger is better at everything".
3. **Time is an estimate with a stated basis**, never a promise.

| Rung | Name | One line | Secondary line | Time shown |
|---|---|---|---|---|
| 0 | Patterns only | Emails, phones, dates, amounts, and ID numbers. | Names, companies, and addresses are not found. | instant |
| 1 | Quick | Finds names, companies, and addresses. | Built in. Ready to use. | about 1 min per contract |
| 2 | Balanced | Finds a little more than Quick and flags less that you have to dismiss. | The best all round choice when your Mac has the memory. | about 2 min per contract |
| 3 | Most thorough | Missed nothing in our testing. | Flags more for you to review, and takes the longest. | about 4 min per contract |

Longer explanations, shown in the Manage Models sheet detail row only:

- **Quick**: "On our test set of twelve contracts in English and Chinese, Quick found 35 of the 36 names, companies, and addresses that had to be caught. About one flag in five was something you would dismiss."
- **Balanced**: "Found the same 35 of 36, and produced the cleanest review queue of the three: roughly one flag in fifteen was something you would dismiss."
- **Most thorough**: "The only option that found all 36. Roughly one flag in eight was something you would dismiss, so expect a longer review."

These sentences are derived from the measured run and must be regenerated, not edited by hand, if the benchmark is re run. The derivation is recorded in section 3.1 so nobody has to reverse engineer it later.

### 3.1 Derivation of the user facing claims

Source: `bench/results/scores-full.json`, full agreement run, two documents of roughly 5,700 characters each.

| Tier model | F1 | Recall | Precision (derived) | Critical strict recall | Critical entities missed | Surface drift | Mean latency |
|---|---|---|---|---|---|---|---|
| Qwen3.5-4B Q4_K_M | 0.847 | 0.920 | 0.785 | 0.972 | 1 of 36 | 0.040 | 53.3 s |
| gemma-4-12b-it Q4_K_M | 0.954 | 0.973 | 0.936 | 0.972 | 1 of 36 | 0.000 | 135.3 s |
| Qwen3.8-27B UD-Q3_K_XL | 0.903 | 0.933 | 0.875 | **1.000** | **0** | 0.067 | 265.1 s |
| `lda-v2` (incumbent) | 0.727 | 0.800 | 0.667 | 0.861 | 5 of 36 | **0.187** | 53.3 s |

"Critical" in the rubric means PERSON, COMPANY, and ADDRESS: the three types with no deterministic backstop in `DeterministicEngine`. A miss there is PII that ships. "About one flag in five you would dismiss" is `1 - precision` rounded to a friendly fraction.

**Time estimator.** Rather than hardcoding the strings, store seconds per 1,000 characters in the manifest and compute the label from the loaded document length where one is available:

| Tier | Seconds per 1,000 characters |
|---|---|
| Quick | 9.4 |
| Balanced | 23.7 |
| Most thorough | 46.5 |

In Settings, where no document is loaded, render against a 5,700 character reference contract and round to the nearest minute. Label everything "about". These figures were measured on the benchmark Mac and are approximate on any other machine; do not present them as a guarantee.

---

## 4. Model acquisition, without a network

### 4.1 The constraint is a feature, and it is not negotiable

`packaging/LDA.entitlements` carries an explicit prohibition:

> DELIBERATELY ABSENT: any network entitlement. This app never touches the network. With the sandbox on and no network entitlement, outbound and inbound network access is denied by the OS, which is the core privacy guarantee for privileged documents. Do not add com.apple.security.network.client or .network.server.

Nothing in this specification adds a network entitlement, a helper process, an XPC service that downloads, or a "just this once" exception. The design below assumes the app can read and write inside its own container and can show text, and nothing more.

**Also rejected: opening the download URL in the user's browser** via `NSWorkspace.open`. It would technically be legal under the sandbox, and LDA itself would still make no connection. It is rejected anyway. The claim the product sells is auditable: a firm's security reviewer should be able to look at the app and find no outbound behaviour of any kind, including handing a URL to another process. One clipboard paste is a small price for a claim that survives scrutiny with no asterisk. Show the URL as selectable text and offer **Copy download link**.

### 4.2 What ships in the bundle

**Bundle Quick, and only Quick.**

- The .app stays at roughly 2.8 GB, which is what it is today. No download size regression.
- Quick is the only tier that runs on a 16 GB Mac under a real working set, so it is the only tier that can be the zero setup default for every supported machine.
- `OnboardingView` already branches on `modelAvailable` and treats a missing model as a degraded state. Shipping an empty app would put every first run into that branch.

Bundling two would push the .app past 10 GB and would still not cover the third. Bundling all three is 23 GB, which is not a product.

### 4.3 The acquisition flow

1. The user picks a tier that is not installed. The row shows **Get Balanced...**, enabled only when the memory gate passes (section 5). Never offer a 7 GB download to a machine that cannot run the result.
2. The sheet explains, in one sentence, that LDA has no network access by design and therefore cannot fetch it, and shows: the model name, the exact file name, the exact size in bytes and GB, and the SHA-256. Buttons: **Copy download link** and **Add downloaded file...**.
3. The user downloads in a browser, or IT places the file on the machine.
4. **Add downloaded file...** opens `NSOpenPanel` filtered to `gguf`, exactly as `AITab.chooseModel()` does today.
5. The app verifies identity (section 4.5), then **copies the file into its own container** with a determinate progress bar and a working Cancel.
6. On success the tier flips to Installed and becomes selectable. On failure the partial copy is deleted and the reason is shown in the sheet.

### 4.4 Storage: copy into the container, do not reference in place

Destination:

```
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  /LDA/Models/<tierID>/<canonicalFileName>.gguf
```

Inside the sandbox this resolves under `~/Library/Containers/com.haotianyi.LDA/Data/...`, which the app owns outright.

This single choice solves three problems at once:

- **No security scoped bookmark is needed for tier models**, ever. The container is always readable, across relaunches, across reboots, after the user reorganises their Downloads folder.
- **The file cannot silently vanish** from under the app because the user tidied up.
- **Removal is a real feature.** "Remove" in Manage Models actually reclaims the disk, and the app can report exactly how much it is using.

Costs, and how to handle them:

- **Disk is briefly doubled.** Precheck free space on the container volume and require `fileSize + 2 GB`. If it fails, say so with both numbers before opening any panel.
- **A 13 GB copy is slow.** Determinate progress, a Cancel that deletes the partial file, and a copy that streams in chunks rather than `FileManager.copyItem` so progress and cancellation are real.
- **The original stays in Downloads.** After a successful import, offer **Reveal original in Finder** and say plainly that the user can delete it now. Do not attempt to move or delete it: the powerbox grant covers the selected file, not its parent directory, so an unlink will fail on some machines and succeed on others, which is the worst kind of behaviour.

**Deferred alternative**: a separately notarized model pack `.pkg` for IT managed deployment, dropping the GGUF into a shared location. Attractive for firms, but it depends on whether a sandboxed app can read the chosen shared path, which has not been verified here. Do not design for it until a spike answers that question. The import flow above has no unknowns.

### 4.5 Identity verification: is this file actually that tier?

**File names are not evidence.** A user can rename anything, quantisation labels are marketing rather than specification (`CANDIDATES.md` documents two "Q4_K_M" builds of the same weights differing by 10.7 percent), and a partially downloaded file often keeps the right name.

Three layers, cheapest first.

**Layer 1: exact byte count.** Compare `resourceValues(forKeys: [.fileSizeKey])` against the manifest. Instant, and it catches truncated downloads and the wrong quantisation immediately.

**Layer 2: GGUF header metadata.** The linked `llama.h` in `Frameworks/llama.xcframework/macos-arm64/Headers/` exposes everything needed:

- `llama_model_params.vocab_only = true` loads metadata **without** allocating weights, so this is fast and costs almost no memory even for the 13 GB file.
- `llama_model_meta_val_str(model, key, buf, size)` reads individual keys.

Check, per the manifest: `general.architecture`, `general.size_label`, `<arch>.block_count`, `<arch>.embedding_length`, `<arch>.attention.head_count`, `<arch>.attention.head_count_kv`. This is precisely the technique that produced the architecture table in `bench/CANDIDATES.md` section 0, and it is what catches a renamed file or a same size model from a different family. It also catches the case that matters most in practice: someone hands a colleague "the good model" and it is actually something else.

**Layer 3: SHA-256 of the whole file.** Definitive, and normally too slow to run on demand for 13 GB. **Compute it during the import copy**: the bytes are already streaming through memory, so hashing them costs no additional I/O and the check is effectively free. Compare against the manifest at the end of the copy. If it does not match, delete the copy.

Verdicts:

| Verdict | Condition | Behaviour |
|---|---|---|
| **Verified** | size, header, and hash all match the manifest | Installed as that tier. Badge: "Verified". Full tier name, time estimate, and memory verdict apply. |
| **Recognised** | header matches the tier, size or hash does not | Accepted, with a caution. Badge: "Different build". Tier name applies, time and memory estimates are labelled approximate. A different quantisation of the right model is a legitimate thing to run. |
| **Unrecognised** | header matches no tier | Accepted as **Custom model** only. No tier name, no badge, no time estimate, no memory verdict. Never silently promoted into a tier slot. |
| **Rejected** | not a valid GGUF, or `vocab_only` load fails | Not installed. Message: "This file is not a model LDA can read." |

Never hard block an unrecognised model. The escape hatch is what makes the app usable by the developer and by a firm with its own tune. Do not label it as something it is not.

### 4.6 The manifest

Ship `Models.json` in the app bundle as the single source of truth for the picker, the verifier, the memory gate, and the time estimator.

```
{
  "schemaVersion": 1,
  "tiers": [
    {
      "id": "quick",
      "displayName": "Quick",
      "bundled": true,
      "fileName": "Qwen3.5-4B-Q4_K_M.gguf",
      "downloadURL": "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/...",
      "sizeBytes": 2740937888,
      "sha256": "TBD",
      "arch": "qwen35",
      "sizeLabel": "4.2B",
      "blockCount": 32,
      "embeddingLength": 2560,
      "peakRSSGB": 3.60,
      "secondsPer1000Chars": 9.4
    },
    { "id": "balanced",     "fileName": "gemma-4-12b-it-Q4_K_M.gguf",  "sizeBytes": 7121861440, "peakRSSGB": 9.21,  "secondsPer1000Chars": 23.7, ... },
    { "id": "mostThorough", "fileName": "Qwen3.8-27B-UD-Q3_K_XL.gguf", "sizeBytes": null,       "peakRSSGB": 13.83, "secondsPer1000Chars": 46.5, ... }
  ]
}
```

**Open items before release.** The three GGUFs live on the benchmark Mac at `/Users/claptrap/lda-bench/models/`, not on the development Mac. Capture from the actual artifacts and paste into the manifest:

- exact `sizeBytes` and `sha256` for all three (`shasum -a 256`, `stat -f %z`)
- the verified HuggingFace repo id and resolve URL for each, especially Qwen3.8-27B, which does not appear in `bench/CANDIDATES.md` and must not be guessed
- the header values (`general.architecture`, `general.size_label`, block count, embedding length, head counts) for gemma-4-12b-it and Qwen3.8-27B

A tier whose manifest row is incomplete must be **hidden entirely**, not shipped with a placeholder. An unverifiable tier is worse than an absent one.

---

## 5. Memory gate

### 5.1 What to probe, and why installed rather than free

Use `ProcessInfo.processInfo.physicalMemory`, the installed RAM.

Free memory at the moment the user opens Settings says nothing about free memory forty seconds into a run with Word, Chrome, and a messaging app awake. Gating on a number that fluctuates would let a user select a tier at a quiet moment and then be failed by it under load, which is the exact failure this gate exists to prevent. Gate on the number that does not move.

### 5.2 The budget function

Take the budgets straight from the benchmark harness (`bench/harness/summarize_tiers.py`), which derived them from a measured office working set of roughly 9 GB plus OS and GPU headroom:

```
installedGB = physicalMemory / 1_073_741_824

budgetGB(installedGB):
    installedGB <= 16  ->  6.5
    installedGB <= 24  -> 14.0
    installedGB <= 32  -> 21.0
    otherwise          -> installedGB - 11.0
```

A tier is **available** when `tier.peakRSSGB <= budgetGB`, and **tight** when it is available with less than 1.0 GB of margin.

Resulting matrix:

| Installed RAM | Budget | Quick (3.60) | Balanced (9.21) | Most thorough (13.83) |
|---|---|---|---|---|
| 8 GB | 6.5 | available | blocked | blocked |
| 16 GB | 6.5 | available | blocked | blocked |
| 24 GB | 14.0 | available | available | available, **tight** (0.17 GB margin) |
| 32 GB | 21.0 | available | available | available |
| 64 GB | 53.0 | available | available | available |

The tight verdict for Most thorough on a 24 GB Mac falls out of the arithmetic rather than being special cased, which is the point.

**Optional secondary guard.** Apple silicon shares one memory pool with the GPU, and `LLMEngine.Config.gpuLayers` defaults to 999, meaning full offload. Where a `MTLDevice` is available, also compare against `recommendedMaxWorkingSetSize` and take the lower verdict. Treat this as a belt and braces addition, not a replacement: the budget function above is the shipping rule.

### 5.3 Presentation: disable and explain, never hide

**Never hide an unavailable tier.**

Hiding produces three bad outcomes: the user cannot tell whether the app is limited or broken; a colleague on a bigger Mac sees a different app with no explanation; and the user never learns the one fact that would let them fix it. A greyed row with a reason teaches something true.

The one exception is section 4.6: a tier with an incomplete manifest is hidden, because the app genuinely knows nothing about it.

Row states:

| State | Selectable | Row copy | Action |
|---|---|---|---|
| Available and installed | yes | tier name, one line, time estimate | radio |
| Available, tight | yes | plus "This Mac has just enough memory. Close other apps before a long document." | radio |
| Available, not installed | no, until installed | plus "Not installed. 8 GB download." | **Get Balanced...** |
| Blocked by memory | no, greyed | plus "Needs 24 GB of memory. This Mac has 16 GB." | none, and no Get button |
| Manifest incomplete | hidden | | |

Copy rules:

- State the requirement and the fact, in that order, in one sentence: "Needs 24 GB of memory. This Mac has 16 GB."
- Never apologise, never say "unsupported", never say "your Mac is too old". The Mac is fine; the model is large.
- Never offer a download for a tier the machine cannot run. A blocked row has no Get button. This is the rule that keeps someone from spending 8 GB of bandwidth on a disappointment.
- The tooltip on a blocked row carries the consequence: "Running a model this large with 16 GB of memory would slow the whole Mac down or stop partway through a document."

### 5.4 Scope of the gate

The gate applies to the Settings ladder only. It does not apply to:

- **The CLI** (`lda anonymize --model`, `lda detect --model`, declared in `Sources/LDACLI/CLI.swift`). A power user on the command line may run whatever they want.
- **The MCP surface** (`modelPath` in `Sources/LDAMCP/MCPServer.swift`).
- **A Custom model** chosen through "Use another model". The app cannot know its footprint, so it must not pretend to.

---

## 6. Default model decision

### 6.1 Decision: replace `lda-v2` with Qwen3.5-4B as the bundled default

Change `LDAApp.defaultModelPath()` (`Sources/LDAApp/LDAApp.swift:222`) to resolve `Qwen3.5-4B-Q4_K_M` from `Bundle.main`, and change `MODEL_PATH` in `packaging/package-app.sh` to match.

### 6.2 Why

**It costs the user nothing.** 2.71 GB against 2.74 GB on disk, 3.57 GB against 3.60 GB of peak memory, and an identical 53.3 second mean latency. Same tier, same machine, same wait.

**It is better on every quality axis measured.** F1 0.727 to 0.847, recall 0.800 to 0.920, and critical strict recall 0.861 to 0.972. In the terms that matter to a lawyer: five names, companies, or addresses missed out of 36 becomes one.

**The decisive reason is surface drift: 0.187 against 0.040.** Surface drift is lenient recall minus strict recall. It counts entities the model *did* find but emitted in a form that does not match the document byte for byte, so `EntityLocator` cannot anchor them and the value stays in the document. Nearly one in five of everything `lda-v2` found fell into this hole. This defect is invisible by construction: the entity never reaches the review queue, so the user cannot catch it by reading carefully. For a tool whose entire job is that nothing privileged escapes, a defect class that cannot be caught by review is disqualifying, independent of the score.

**A secondary benefit**: removing the fine tune removes a bespoke artifact from the release pipeline. The default becomes a public, reproducible, verifiable file with a published hash, which is exactly what section 4.5 needs to work.

**On the sunk cost.** The fine tune was evaluated against its own base with the base as the control group, which is the only comparison that answers the question. The answer came back negative. Keeping it as the default because it was expensive to make would be the most expensive possible way to pay for it.

### 6.3 Compatibility invariant

**Changing the model must not change what an existing mapping restores.** The model affects detection only. Placeholder allocation, the mapping format, the encrypted container, and `Restorer` are all downstream of the span list and are not model dependent. Old sessions restore identically.

This is a claim, so it needs a test rather than an assertion. See AC-27.

### 6.4 Migration

**Users on the bundled default** (`customModelPath == ""`, which is the overwhelming majority) get the new model on update with no prompt and no decision to make. Mention it once in the release note, in consequence terms: "The built in model is better at finding names and misses far less. Nothing about your saved sessions changes."

**Users who explicitly selected an `lda-v2-*.gguf`** keep running it. Never silently override an explicit choice. On first launch after the update, show a one time, dismissible notice at the top of the AI tab:

> The model you chose misses about one in five of the names it finds, because of small formatting differences between what it reports and what is in your document. Those never reach your review list. The built in model does not have this problem and is the same speed.
> [ Switch to Quick ]   [ Keep using my model ]

Record the dismissal so it never appears twice. If the user keeps it, it becomes a **Custom model** rung as described in section 2.4.

**Retire the bundled `lda-v2` resource in the same release.** Also update the developer fallback in `LDAApp.defaultModelPath()`, which currently points at `~/Developer/lda-models/lda-v2-Q4_K_M.gguf`. Any stored path pointing inside the old app bundle will stop resolving; this is covered by the missing model handling in section 7.

Keep `lda-v2` downloadable from the same place as the tier models for one release, listed under "Use another model", for anyone who needs to reproduce an old comparison.

---

## 7. States and edge cases

### 7.1 The existing bug: a stored path is not a durable grant

This is a live defect in shipped code, and the tier work must not be built on top of it.

**What the code does now.** `AISettings.customModelPathKey` stores a plain `String` path written by `AITab.chooseModel()` from an `NSOpenPanel` result. Nothing in `Sources/` calls `bookmarkData` anywhere; the only sandbox scoping in the codebase is transient `startAccessingSecurityScopedResource()` around document URLs in `AppShell.swift`, `DocumentPane.swift`, `FillShell.swift`, and `FillModel.swift`.

**Why that breaks.** `packaging/LDA.entitlements` enables `com.apple.security.app-sandbox` with only `com.apple.security.files.user-selected.read-write`. The powerbox grant from an open panel is not durable across launches without a persisted security scoped bookmark. On the next launch, `FileManager.default.fileExists(atPath:)` on that path returns false because `stat` is denied, so `AISettings.customModelPath()` returns nil and `resolveModelPath` quietly falls back to the bundled model. The user's chosen model stops being used with no event of any kind.

**How it compounds.** `ReviewModelDetection.llmSpans` (`Sources/LDAUI/ReviewModelDetection.swift:154`) handles the missing file by returning `LLMPassOutcome(spans: [], attempted: false, failure: nil, ...)`. That is the "AI was not requested" contract, used for a case where the AI *was* requested and could not run. The consequence: `aiFailure` is nil, so `ReviewModel.aiWarning` stays nil, and the only signal is `aiActive == false`, which renders in `AppShell.swift:369` as a red "Pattern matching only" badge whose explanation lives in a `.help()` tooltip.

That badge is not nothing, but it is not enough, for one specific reason: **it is the same badge that a user sees when they deliberately chose Patterns only.** An indicator that fires in a normal, intended configuration is an indicator people stop reading. A lawyer who picked Balanced and got pattern matching sees an indicator they have been trained by their own settings to ignore, and the words that would explain it are behind a hover.

The file header of `ReviewModelDetection.detect` states the intended invariant directly: an LLM failure "is REPORTED in the outcome so the UI can warn; a silent degrade would let the lawyer trust a pattern-only pass as an AI pass". The missing model branch does not honour it.

**Required fixes, all P0, all in this release:**

- **F1.** Import by copy into the container (section 4.4) removes the whole problem class for tier models. No bookmark is involved because no path leaves the sandbox.
- **F2.** For any path outside the container, which after this change means only a Custom model, persist a security scoped bookmark alongside the path and wrap every use in `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`. This requires adding to `packaging/LDA.entitlements`:

  ```
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
  ```

  **This is not a network entitlement and does not weaken the offline guarantee.** Add a comment saying so directly above it, in the same voice as the existing prohibition, so that a future reader does not "clean it up" and silently reintroduce this bug.
- **F3.** `llmSpans` must distinguish "AI was not asked for" from "AI was asked for and could not run". The missing or unreadable model branch returns `attempted: true` with a `failure` string, so `aiWarning` is populated and the visible banner carries words rather than a tooltip.
- **F4.** The "Pattern matching only" indicator must read differently in the two cases:
  - user chose Patterns only: neutral styling, "Patterns only, as you chose."
  - AI was expected and did not run: danger styling, "Balanced could not run. This was patterns only. Names and companies may have been missed." plus a **Fix in Settings** button.

### 7.2 State matrix

| # | Condition | Detection behaviour | User sees | Recovery |
|---|---|---|---|---|
| E1 | Selected tier installed and verified | runs | tier name in the banner | none needed |
| E2 | Selected tier file deleted from the container while the app is closed | falls back to Quick if installed, otherwise Patterns only | danger banner naming the tier that failed, plus **Fix in Settings**; the tier row shows "Not installed" | Get it again |
| E3 | Selected tier file present but truncated or corrupt (`LLMEngine` throws `modelLoadFailed`) | this pass is patterns only | danger banner: "Balanced could not be loaded. The file may be damaged." | Manage Models offers **Remove and add again** |
| E4 | Custom model path unreadable after relaunch (bookmark stale or file moved) | this pass is patterns only | danger banner naming the file, plus **Fix in Settings** | re-choose the file, which mints a new bookmark |
| E5 | User upgrades RAM, or the machine changes | gate re-evaluates every time the AI tab appears and at launch | previously blocked tiers become selectable | none needed |
| E6 | User downgrades to a Mac with less RAM, restoring from a backup, with a tier selected that no longer fits | at launch, if the selected tier fails the gate, fall back to the highest tier that passes | one time notice: "Most thorough needs more memory than this Mac has. LDA switched to Quick." | pick another |
| E7 | Disk fills during an import copy | copy aborts, partial file deleted | "Not enough space. gemma-4-12b-it needs 7.12 GB and there is 3.1 GB free." | free space, retry |
| E8 | User cancels an import copy | partial file deleted, tier remains Not installed | sheet returns to its idle state | retry |
| E9 | Imported file fails the hash check | copy deleted | "This file does not match the published Balanced model. It may have downloaded incompletely." with the expected and actual size | download again |
| E10 | Imported file has an unrecognised header | installed as Custom model only | "LDA does not recognise this model, so it cannot tell you how it will perform." | use it, or remove it |
| E11 | Two tiers installed, user switches | previous model unloaded, next used on the next detection run | tier name updates in the banner | none needed |
| E12 | Model runs but cannot fully scan (`fullyCovered == false`) | existing behaviour, already correct | existing warning about unscanned segments | re-run |
| E13 | User stops a run mid pass | existing behaviour, `cancelled` | no false completed state | none needed |
| E14 | `Models.json` missing or unparseable in the bundle | Quick only, from `Bundle.main`, no tier UI | AI tab shows the ladder with Patterns only and Quick, no Manage Models | reinstall |

---

## 8. Acceptance criteria

A QA engineer should be able to execute this list without reading the rest of the document. "The 16 GB Mac" and "the 24 GB Mac" mean physical machines or VMs with that installed RAM.

### Information architecture

- **AC-1** Settings > AI shows exactly one ladder. The words "Fast" and "Thorough" appear nowhere in the AI tab.
- **AC-2** The ladder shows four rungs in order: Patterns only, Quick, Balanced, Most thorough.
- **AC-3** Selecting Patterns only and running a detection produces zero PERSON, COMPANY, or ADDRESS spans and completes in under two seconds on a 20 page document.
- **AC-4** Selecting any other rung and running a detection produces at least one PERSON or COMPANY span on `bench/fulldocs/full-en-agreement.json`.
- **AC-5** With `detectionMode = "fast"` written to `UserDefaults` before launch and no `detectionLevel` key, the app starts on Patterns only.
- **AC-6** With `detectionMode = "thorough"` and an empty `customModelPath`, the app starts on Quick.
- **AC-7** With `detectionMode = "thorough"` and `customModelPath` pointing at a readable non tier GGUF, the app starts on a Custom model rung showing that file name.
- **AC-8** After migration, `com.haotianyi.LDA.detectionModeKey` is still present in `UserDefaults` and is not read by any code path (assert by unit test).

### Copy

- **AC-9** No digit sequence resembling a score (`0.847`, `95%`, `F1`) appears anywhere in the AI tab or the Manage Models sheet.
- **AC-10** Every rung shows a time estimate prefixed with "about", except Patterns only, which shows "instant".
- **AC-11** With a document loaded, the time estimate is computed from the document's character count and the manifest's `secondsPer1000Chars`, not from a constant string (assert by unit test at two different document lengths).
- **AC-12** No em dash or en dash appears in any string added by this feature (assert by a grep in CI over `Sources/`).

### Acquisition

- **AC-13** The shipped `LDA.app` contains exactly one `.gguf` in `Contents/Resources`, and its name is `Qwen3.5-4B-Q4_K_M.gguf`.
- **AC-14** `packaging/LDA.entitlements` contains neither `com.apple.security.network.client` nor `com.apple.security.network.server`.
- **AC-15** Running the packaged app under a network monitor (`nettop -p <pid>`, or Little Snitch) through a full import and detection cycle shows zero connection attempts.
- **AC-16** The Manage Models sheet contains no control that opens a URL. `NSWorkspace.open` does not appear in any file added or changed by this feature.
- **AC-17** **Copy download link** places the manifest URL on the clipboard, and the same URL is visible as selectable text in the sheet.
- **AC-18** Importing a valid `gemma-4-12b-it-Q4_K_M.gguf` copies it into `Application Support/LDA/Models/balanced/` and Balanced becomes selectable.
- **AC-19** After AC-18, quit the app, move the source file to the Trash, relaunch, and run a detection on Balanced. It runs. The banner shows Balanced. (This is the regression test for the bookmark class of bug.)
- **AC-20** Cancelling an import mid copy leaves no file in `Application Support/LDA/Models/`.
- **AC-21** Importing a file truncated to half its size is refused with a message naming the expected and actual size, and nothing is left behind.
- **AC-22** Importing `Qwen3.5-4B-Q4_K_M.gguf` renamed to `gemma-4-12b-it-Q4_K_M.gguf` is **not** accepted as Balanced. The header check catches it and the file is offered as a Custom model or refused.
- **AC-23** Importing an arbitrary non GGUF file renamed to `.gguf` is refused with "not a model LDA can read", and the app does not crash or hang.
- **AC-24** With free disk space below `fileSize + 2 GB`, the import is refused before any panel opens, and the message states both numbers.
- **AC-25** Remove on an installed tier deletes the file, the reported disk usage drops by that amount, and the tier returns to Not installed.

### Default model

- **AC-26** A fresh install with no `UserDefaults` runs Qwen3.5-4B on its first detection. Confirm by loading a document, running detection, and checking the banner and the `LLMEngine` load log under `LDA_PERF`.
- **AC-27** **Round trip across a model change.** Anonymize a document with `lda-v2`, save the mapping, switch the default to Qwen3.5-4B, restore that mapping, and diff against the original. Output is byte identical. Repeat with a DOCX and a PDF.
- **AC-28** With `customModelPath` pointing at an `lda-v2-*.gguf`, the one time switch notice appears once, and does not reappear after being dismissed or after a relaunch.
- **AC-29** Choosing **Keep using my model** in that notice leaves `customModelPath` unchanged and shows a Custom model rung.
- **AC-30** `LDAApp.defaultModelPath()` no longer references `lda-v2-Q4_K_M` in either the bundle branch or the `~/Developer/lda-models` fallback branch.

### Memory gate

- **AC-31** On the 16 GB Mac: Balanced and Most thorough are **visible**, greyed, not selectable, and each shows "Needs 24 GB of memory. This Mac has 16 GB." Neither shows a Get button.
- **AC-32** On the 16 GB Mac, clicking a blocked row changes nothing. Keyboard focus skips it.
- **AC-33** On the 24 GB Mac: all four rungs are selectable, and Most thorough additionally shows the tight memory caution.
- **AC-34** On the 32 GB Mac: all four rungs are selectable and Most thorough shows no caution.
- **AC-35** The budget function is unit tested at 8, 16, 24, 32, and 64 GB against the table in section 5.2.
- **AC-36** `lda anonymize --model <balanced gguf>` on the 16 GB Mac is **not** blocked by the gate. It may be slow; it must not be refused by LDA.
- **AC-37** With a tier selected that the current machine cannot run (simulate by writing `detectionLevel = "mostThorough"` on the 16 GB Mac), the app falls back at launch to the highest passing tier and shows the one time notice from E6.

### Failure reporting

- **AC-38** Delete the selected tier's file from the container while the app is closed, relaunch, and run a detection. A **danger** banner appears with visible text naming the tier that failed, not only a tooltip, plus a **Fix in Settings** action.
- **AC-39** With Patterns only selected, the banner is **not** styled as an error and reads as an intentional state.
- **AC-40** AC-38 and AC-39 produce visually distinguishable banners. Screenshot both and confirm.
- **AC-41** Corrupt an installed tier file (truncate to 1 MB), run a detection, and confirm the app reports a load failure and does not crash.
- **AC-42** In every failure case above, the export path treats the pass as pattern only and does not present it as a completed AI pass.

### Production configuration

- **AC-43** **Re-measure peak RSS under the production configuration**, not the benchmark harness one. The published figures were taken with `llama-server -np 1` at `ctx 12288`, while production `LLMEngine.Config` defaults to `contextLength: 8192`, `batchSlots: 4`, `n_batch` equal to the context length, and `gpuLayers: 999`. Measure peak RSS of `LDAApp` itself for each of the three tiers on a full document. If any tier's measured peak exceeds its manifest `peakRSSGB`, update the manifest before shipping, and re-run AC-31 through AC-34.
- **AC-44** Existing test suite passes with no skips.

---

## Action list

| # | Action | Owner | Window |
|---|---|---|---|
| 1 | Capture exact bytes, SHA-256, repo URLs, and GGUF header values for all three tier models from the benchmark Mac, and fill `Models.json` | Engineering | before any UI work |
| 2 | Re-measure peak RSS under production `LLMEngine.Config` defaults for all three tiers (AC-43) | Engineering | before the memory gate is finalised |
| 3 | Land F1 through F4 from section 7.1 (container import, app scope bookmark entitlement, honest `llmSpans` reporting, two banner states) | Engineering | first, independently shippable |
| 4 | Introduce `DetectionLevel`, migrate `DetectionMode`, rebuild `AITab` as the ladder | Engineering | after 3 |
| 5 | Swap the bundled default to Qwen3.5-4B, update `package-app.sh`, write the switch notice | Engineering | with 4 |
| 6 | Manage Models sheet, import with progress and hash during copy, identity verification | Engineering | after 4 |
| 7 | Verify AC-15 and AC-16 on a signed, notarized build under a network monitor | QA | before release |

---

## Assumptions, open questions, and non-goals

**Assumptions**

- The three tier models remain downloadable from stable public URLs. If a repo moves, the manifest ships a dead link and the only recourse is an app update. Accepted for v1; a "the link did not work" note in the sheet pointing at the file name and hash lets a user find it elsewhere.
- The measured office working set of roughly 9 GB is representative. A user running Docker or a VM will find the gate optimistic. The tight caution copy partially covers this.
- The benchmark's twelve document corpus plus two full agreements generalises to real contracts. It is a small sample. The tier ordering is stable across it, but the exact fractions in section 3 are not precision instruments.

**Open questions**

- Q1. Can a sandboxed LDA read a GGUF from a shared, IT deployed location? Blocks the `.pkg` model pack option in section 4.4. Needs a spike.
- Q2. Should Balanced be the default on machines that can run it, given that it has both the highest F1 and the highest precision? This spec says no: the default must be identical on every machine so that two lawyers at the same firm get the same output from the same document. Worth revisiting with real usage.
- Q3. Does the fine tune have any residual advantage on Chinese documents specifically, below the resolution of the current corpus? Not a blocker for the swap, since surface drift disqualifies it regardless.

**Non-goals, restated so nobody adds them back**

- No network entitlement, no download helper, no URL opening.
- No automatic tier escalation.
- No per document tier override in v1.
- No telemetry.

---

## Appendix: implementation map

| Change | File |
|---|---|
| `DetectionLevel`, migration, `resolvedPath(for:)`, keep `apply(to:bundledDefault:)` signature | `Sources/LDAUI/AISettings.swift` |
| Rebuild `AITab` as the ladder; add the Manage Models sheet | `Sources/LDAUI/SettingsView.swift` |
| Honest missing model reporting in `llmSpans`; keep the `DetectionOutcome` contract | `Sources/LDAUI/ReviewModelDetection.swift` |
| Two banner states for `aiActive == false` | `Sources/LDAUI/AppShell.swift` (around line 369) |
| Bundled default resource name and the developer fallback path | `Sources/LDAApp/LDAApp.swift` (`defaultModelPath()`, line 222) |
| `MODEL_PATH` default and the bundled resource name | `packaging/package-app.sh` |
| Add `com.apple.security.files.bookmarks.app-scope` with a comment explaining it is not a network entitlement | `packaging/LDA.entitlements` |
| New: manifest type, tier store, install and verify, memory gate | `Sources/LDAUI/ModelCatalog.swift`, `Sources/LDAUI/ModelInstaller.swift`, `Sources/LDAUI/MemoryBudget.swift` |
| New: GGUF header probe via `vocab_only` load and `llama_model_meta_val_str` | `Sources/LDACore/Engine/GGUFMetadata.swift` |
| New: `Models.json`, copied into `Contents/Resources` by the packaging script | `packaging/Models.json` |
| First run copy when no model is available (already branches on `modelAvailable`) | `Sources/LDAUI/OnboardingView.swift` |

Unchanged by design: `Restorer`, `MappingStore`, `EncryptedContainer`, `SessionRecordStore`, the placeholder scheme, and every CLI and MCP signature.

---

## Appendix M: production config re-measurement (resolves AC-43)

The spec flagged as its highest risk that every tier RAM figure came from the
benchmark harness (`llama-server -c 12288 -np 1`) rather than the production
`LLMEngine.Config` defaults (`contextLength: 8192`, `batchSlots: 4`,
`gpuLayers: 999`). Re-measured on the Mac mini M4 under the production values:

| Tier | Harness (-np 1, ctx 12288) | Production (-c 8192 -np 4) | Delta |
|---|---|---|---|
| Quick, Qwen3.5-4B | 3.60 GB | **3.11 GB** | -0.49 |
| Balanced, gemma-4-12b | 9.21 GB | **8.48 GB** | -0.73 |
| Most thorough, Qwen3.8-27B Q3_K_XL | 13.83 GB | **12.16 GB** | -1.67 |

Production is LOWER, not higher. With `-np 4` llama.cpp divides the requested
context among the slots (`n_ctx_slot = 2048` was logged for all three), so the
production KV pool is smaller than the harness pool of 12288. The gate built on
the harness numbers is therefore conservative in the safe direction.

One consequence worth carrying into the gate table: Most thorough on a 24 GB Mac
has 1.84 GB of margin under production config, not the 0.17 GB computed from
harness numbers, so it no longer meets the section 5.2 definition of **tight**.

Use the harness numbers for the shipping gate anyway. They are conservative, and
`contextLength` and `batchSlots` are engine defaults a future change could raise,
which would move production consumption back up toward them.

Separate observation, not part of this feature: at `-np 4` each sequence gets
only 2048 tokens of context, while a whole Chinese agreement in the benchmark
tokenised to 3492. Production chunks documents so this is not necessarily a
defect, but the interaction between `batchSlots`, per-slot context, and the
oversized-retry path in `LLMExtractor` deserves its own check.


---

## Appendix N: superseded decision, nothing is bundled

Section 4.2 specified bundling the Quick model and installing only Balanced and
Most thorough. **That is superseded: the app now ships with no model weights at
all.** All three tiers are downloaded by the user and installed into
`Application Support/LDA/Models/`.

What changed, and what it means:

- `LDAApp.defaultModelPath()` is **deleted**. There is no bundled resource and no
  developer-location fallback. The initial model path is whatever the selected
  detection level resolves to in the container, which is nil on a fresh install.
- `AISettings.resolveModelPath` and `isModelMissing` no longer take a
  `bundledDefault`, and `apply(to:)` lost the parameter. A rung with no installed
  file resolves to nil, full stop. No rung can borrow another rung's model.
- `package-app.sh` no longer copies a GGUF and ignores `MODEL_PATH` with a
  warning. The distributed artifact contains no third-party model weights, and
  the `.app` drops from roughly 2.8 GB to tens of megabytes.
- Quick is no longer described as "Built in". Every model rung shows its download
  size and requires installation before it can be selected.
- The first run of a fresh install has NO AI pass. This is the normal state, not
  an error. Onboarding says so and names the next step, and any scan at a model
  rung reports "AI did not run" through the section 7 reporting path rather than
  silently producing a patterns-only result.

The section 6 default-model decision still stands in substance: lda-v2 is retired
and is referenced nowhere except the one-time switch offer for users who chose it
explicitly. Qwen3.5-4B backs the Quick rung, but as a download rather than a
bundled file.

Section 4.3's acquisition flow becomes more load bearing, not less: it is now the
only way any user gets any model, so AC-17 through AC-25 move from "next release"
to "required for the feature to function at all".
