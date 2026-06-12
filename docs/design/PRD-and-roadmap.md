# LDA.app — Product Requirements Document and Roadmap

Native macOS legal document anonymizer for cross-border lawyers and small legal
teams. Runs fully offline, on-device, with no network entitlement.

Status date: 2026-06-07
Source of truth for "shipped": macos/LDACore (LDACore, LDAUI, lda, lda-mcp,
LDAApp, packaging). Full hybrid pipeline works end-to-end on-device; app launches
as a real bundle that loads the model from Bundle.main.

---

## 1. Problem Statement

Cross-border lawyers routinely send privileged, confidential client documents
(contracts, engagement letters, term sheets, board minutes) to third-party tools
for translation, summarization, redlining, and AI drafting. Every upload of an
unredacted privileged document to a cloud service is a confidentiality and
privilege risk (ABA Model Rule 1.6, NY RPC 1.6) and, for EU/PRC counterparties,
a data-transfer risk (GDPR, PIPL). Manual redaction in Word or Acrobat is slow,
error-prone, irreversible, and easy to get wrong (hidden text, copy-paste of
black boxes, missed occurrences).

Lawyers need to strip names, companies, addresses, IDs, bank accounts, amounts,
and dates out of a document before it leaves their machine, work with the
redacted version anywhere, and then deterministically restore the original
values when the work product comes back. The redaction and the restore must both
be trustworthy: nothing should silently leak, and nothing should silently break.

## 2. Target Users and Top Jobs-to-be-Done

Primary user: a New York-based cross-border lawyer handling US/EU/PRC matters,
working with English and Chinese documents.

Secondary users: small legal teams (boutique firms, in-house legal at SMEs) who
want a shared, consistent redaction vocabulary and no IT-managed cloud DLP.

Top jobs-to-be-done:

1. "Before I paste this contract into an AI tool or send it to a vendor, strip
   every client identifier out of it on my own machine."
2. "Let me review what will be redacted, and override the machine's guesses,
   before anything is written."
3. "When the redacted document comes back edited, put the real names and numbers
   back, exactly, without hand-editing."
4. "Teach the tool my client names and matter-specific terms once, and have it
   remember them."
5. "Share my redaction vocabulary with my associate so we redact consistently."
6. "Prove to myself (and to a supervising partner) that the redaction is
   complete before I rely on it."

## 3. Goals and Non-Goals

### Goals

- Fully offline, on-device anonymization with a hard no-network guarantee
  enforced by the OS sandbox (no network entitlement).
- High-recall detection of both structured PII (deterministic + checksum) and
  fuzzy entities (PERSON / COMPANY / ADDRESS via a bundled local LLM).
- Human-in-the-loop review: the lawyer accepts or rejects each detection before
  any redacted file is written.
- Byte-exact, deterministic restore round-trip.
- First-class Chinese support (身份证 checksum, USCC checksum, Chinese dates and
  amounts, Chinese role labels never redacted).
- Format fidelity: .docx round-trips run-preserved; PDF gets a visual review
  artifact; plain text supported.
- Encrypted-at-rest mapping sidecar (AES-GCM, Keychain or passphrase).
- A single shared core behind three faces: app, CLI, MCP server.

### Non-Goals

- No cloud sync, no account system, no telemetry, no auto-update server.
- Not a general DLP or e-discovery platform; scope is single-document redaction
  and restore.
- Not a translation or drafting tool; LDA hands off to those tools, it does not
  replace them.
- No attempt to redact entities inside embedded images beyond OCR text;
  pixel-level scrubbing of logos/signatures is out of scope for v1/v1.x.
- No Windows or web version in this roadmap.

## 4. The Privileged-Document / Offline Value Proposition

LDA's core promise is structural, not aspirational: the shipped app bundle
(packaging/LDA.entitlements) turns the App Sandbox on and grants only
user-selected file read/write. It deliberately ships no
com.apple.security.network.* entitlement, so the operating system itself denies
all outbound and inbound network access to the process. The bundled GGUF model
runs locally via llama.cpp with Metal; detection never calls a server.

For a lawyer, this converts a policy question ("do I trust this vendor with
privileged data?") into a verifiable system property ("this binary cannot reach
the network, by macOS sandbox enforcement"). That is the differentiator against
every cloud redaction or cloud-LLM tool, and it is the claim the product is built
to defend. It is the reason no feature on this roadmap may introduce a network
entitlement.

## 5. Feature Inventory

### 5.1 SHIPPED

Detection and pipeline (LDACore):

- DeterministicEngine: regex + checksum detection for EMAIL, PHONE, NATIONAL_ID
  (Chinese 身份证 with ISO-7064 mod-11-2 checksum), USCC, BANK_ACCOUNT, DATE
  (ISO / slashed / Chinese 年月日), AMOUNT (symbol/code-prefixed and Chinese
  万/亿 suffixed). UTF-16 offset convention.
- Role-label denylist: Buyer/Seller/甲方/乙方 and similar are never redacted.
- LLMEngine: bundled Qwen3.5-4B GGUF via llama.cpp/Metal, on-device.
- LLMExtractor: chunked extraction of PERSON / COMPANY / ADDRESS.
- SpanMerger: deterministic-wins overlap resolution.
- Tokenizer: opaque {TYPE_N} tokens, one per distinct surface value.
- Restorer: pure deterministic token-to-value substitution with an orphan-token
  guard.
- CustomPatternEngine: user vocabulary (literal + regex), highest priority.
- DocumentIO: .docx (run-preserving redact + restore), .txt, PDF (text layer),
  Vision OCR fallback for scanned PDF; PDF visual review artifact via PdfRedactor.
- MappingStore: AES-GCM encrypted .ldamap sidecar, Keychain or passphrase.
- LDAService facade: anonymize / restore / detect, clock-injected for purity.

App (LDAUI / LDAApp), the "Counsel" window:

- Open (.txt/.docx/.pdf via NSOpenPanel), drop-zone, paper-document review pane.
- Anonymize with determinate progress + ETA; re-runnable.
- Entity review sidebar: grouped by value, accept/reject individually or per
  group.
- In-place text editing before export.
- Export: directory picker + optional passphrase sheet; writes redacted edit
  surface + encrypted .ldamap; File > Export (Cmd+E) and toolbar Export.
- AI detection always on (degrades gracefully to deterministic-only if no model).
- Settings: General (Appearance: System/Light/Dark), Vocabulary (literal/regex
  custom terms), Learned (on-device learning from accept/reject with forget),
  Sharing (export/import a combined vocabulary + learned-memory profile, merge
  semantics).
- Adaptive light/dark theme; Counsel visual direction.

CLI and MCP (lda, lda-mcp):

- lda anonymize / restore / detect with --input/--output-dir/--passphrase/--model.
- MCP stdio server exposing the same three operations with --model.

Packaging:

- Offline .app bundle with sandbox-on, no-network entitlements.
- Bundles the GGUF model; loads it from Bundle.main.
- package-app.sh builds unsigned always; signs + notarizes when
  CODESIGN_IDENTITY / NOTARY_PROFILE are set.

### 5.2 PLANNED (not yet built)

- In-app Restore / de-anonymize flow (engine + CLI support it; window does not).
- App icon (AppIcon.icns + CFBundleIconFile).
- A completeness / confidence verification affordance in the review UI.
- Final signed + notarized distributable build (needs the user's Apple Developer
  ID; tooling is ready).
- Passphrase-encrypted shareable vocabulary/learned profiles.
- "Re-run on vocabulary change" convenience.
- A learning-threshold setting.
- Scanned-PDF visual-redaction polish.

## 6. Key User Flows

Flow A — Anonymize before sending out:
Open document, click Anonymize, watch progress/ETA, review the grouped entity
sidebar, reject false positives and accept the rest, optionally edit text,
Export to a folder with an optional passphrase. Out: redacted .docx/.txt (+ PDF
review artifact for PDFs) and an encrypted .ldamap.

Flow B — Restore when work product returns (PLANNED in-app; available via CLI):
Open the edited redacted file + its .ldamap, supply the passphrase if any,
Restore, write the re-identified document. The orphan-token guard reports any
tokens the editor left dangling.

Flow C — Teach and reuse vocabulary:
Add client names / matter terms in Settings > Vocabulary; accept/reject decisions
feed Learned memory; export the combined profile in Sharing and hand it to an
associate, who imports and merges it.

Flow D — Verify completeness (PLANNED):
After review, see a per-type count and a confidence/coverage summary, and a clear
"unredacted candidates remaining" signal, before trusting the export.

## 7. Success Metrics (desktop legal tool, no telemetry)

- Detection recall on a curated internal corpus: target >= 0.97 recall on
  PERSON/COMPANY and 1.0 on checksum-validated structured PII, measured per
  release.
- Restore fidelity: 100% byte-exact round-trip on the test corpus; zero silent
  orphan tokens in the happy path.
- Review burden: median number of manual corrections per document trending down
  as learning accrues.
- Time-to-redact: median wall-clock from Open to Export under a target (e.g.
  under 60s for a typical 5-10 page contract on Apple Silicon).
- Trust: user can state, unprompted, that the app cannot reach the network.
- Adoption proxy: documents processed per week; shared profiles imported by
  teammates.

## 8. Risks

- Model recall on real contracts (HIGH). Human review mandatory before write;
  deterministic layer covers structured PII independently; verification affordance
  (PLANNED) surfaces residual risk; vocabulary + learning close recurring gaps.
- .docx / PDF edge cases (HIGH). Run-split text, tracked changes, headers/footers,
  tables, scanned PDFs. Maintain an adversarial fixtures corpus; PDF gets a visual
  review artifact rather than claiming in-place edit.
- Trust / verification of redaction completeness (HIGH). Never present a redacted
  file as "clean" without a residual-candidate signal. The verification affordance
  is in the v1 ship set.
- Signing / distribution (MEDIUM). Notarization can reject the Metal/JIT binary;
  packaging tooling and the allow-jit fallback are ready.
- Mapping-key handling (MEDIUM). Lost passphrase => no restore; leaked .ldamap =>
  re-identification. AES-GCM at rest; clear passphrase UX; PLANNED encrypted
  shareable profiles.
- Model footprint (LOW/MEDIUM). ~2.7GB bundled GGUF. Acceptable for desktop;
  optional managed model later, preserving the offline guarantee.

---

## 9. Roadmap

Effort key: S = up to ~1 day, M = a few days, L = ~1-2 weeks. Sequenced.

### v1 Ship — "Safe to hand to a lawyer"

1. In-app Restore / de-anonymize flow (M). Wire LDAService.restore + the CLI
   logic into the window: open edited redacted file + .ldamap, passphrase sheet,
   write restored output, surface the orphan-token report. The only missing half
   of the core round-trip.
2. Redaction-completeness / confidence verification affordance (M). Per-type
   counts, low-confidence flags, and a visible "unredacted candidate" signal in
   review and at export. Mitigates the top trust risk.
3. App icon (S). AppIcon.icns + CFBundleIconFile. Blocking for a credible,
   notarizable product.
4. Signed + notarized build with the user's Apple Developer ID (S + one manual
   signing step). Run package-app.sh with CODESIGN_IDENTITY / NOTARY_PROFILE;
   handle any JIT/hardened-runtime notarization rejection via allow-jit.

v1 acceptance: a lawyer can install a notarized LDA.app, anonymize a real
contract, verify completeness, export, and later restore the edited file back to
originals, entirely offline.

### v1.x — Hardening and team workflow

5. Passphrase-encrypted shareable profiles (M).
6. "Re-run on vocabulary change" (S).
7. Learning-threshold setting (S).
8. .docx / PDF edge-case fixtures and fixes (L).

### v2 — Reach and fidelity

9. Scanned-PDF visual-redaction polish + true rasterized redaction option (L).
10. Optional model management (M/L), preserving the no-network offline guarantee.
11. Recall-tuning loop on the internal corpus (M).
