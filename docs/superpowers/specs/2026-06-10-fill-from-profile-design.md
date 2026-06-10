# Fill from Profile: design spec

Date: 2026-06-10
Status: approved by user (design conversation, this session)
Target codebase: native macOS app ("Counsel") at `macos/LDACore` on branch `feat/lda-macos-core`
House rules: all code comments and strings in English; no em-dash and no en-dash-as-separator anywhere, including this document.

## 1. Problem and goal

When a lawyer drafts a document from scratch for an incorporation matter, the facts already exist in source documents on hand: the certificate of incorporation and the articles of association, usually as PDFs (sometimes scanned). Today the lawyer retypes those facts into every draft and every form.

The feature: extract the sensitive facts from the source documents once, using the on-device model only, into a reviewed, encrypted Company Profile. Then fill the blanks of any target document (DOCX draft or AcroForm PDF form) from that profile, with per-blank review before anything is applied.

This is the inverse direction of anonymization (real values are inserted, not removed), built from the same machinery: importers, OCR, the llama.cpp engine, run-preserving DOCX editing, encrypted at-rest storage, and the keyboard-first review UI.

### Goals

- Extract a structured Company Profile from one or more source documents, fully on-device.
- Each profile field carries provenance: source document name, verbatim source snippet, confidence.
- Persist the profile encrypted (same protection options as mapping sidecars). Reuse across many target documents in the same matter.
- Detect blanks in DOCX drafts (bracketed labels, underscore runs, handlebars, guillemets) and in AcroForm PDFs (text widgets).
- Match blanks to profile fields deterministically first (label synonym table), with the on-device model as fallback for unlabeled or unmatched blanks.
- Review every proposed fill before applying. Apply to a new output file, never the original.
- Surfaces: Counsel UI (primary), CLI and MCP (thin wrappers over the facade, final phase, cuttable).

### Non-goals (V1 scope cuts)

- No filling of flat PDFs whose blanks are only visual lines (no AcroForm fields).
- No auto-fill of checkbox, radio, or choice widgets; these are listed in the report as manual items.
- No plain-text or Markdown targets.
- One profile per fill run. Blanks belonging to a counterparty stay unmatched; multi-profile fill is a noted future extension.
- No cross-field validation (for example issued capital not exceeding authorized capital).
- No silent auto-fill mode on any surface.

## 2. User workflow

1. In Counsel, the lawyer opens the new Fill mode and adds source documents (PDF born-digital or scanned, DOCX, or text; the import path is the same one anonymize uses, including the OCR fallback).
2. The on-device model extracts candidate profile fields. The lawyer reviews the profile: each field shows its value, source document, and verbatim snippet; values are editable; conflicts are flagged for an explicit choice.
3. The lawyer saves the profile as an encrypted `.ldaprofile` (passphrase or Keychain protection, as with `.ldamap`).
4. The lawyer opens a target document (DOCX draft or AcroForm PDF) against the profile. Counsel lists every detected blank with a proposed value where a match exists.
5. The lawyer walks the list with the same keyboard-first interaction as entity review: accept, reject, or repoint a blank at a different profile field via a picker. Format-adapted proposals are shown next to the verbatim profile value.
6. Apply writes a new filled file next to the original (never overwriting it) plus a value-free fill report.

## 3. Domain types

New file `macos/LDACore/Sources/LDACore/Domain/ProfileTypes.swift`. Frozen public types, same conventions as `CoreTypes.swift` (Codable, Sendable, UTF-16 offset convention where spans appear).

- `ProfileFieldKey`: enum with canonical cases and a custom escape hatch.
  - Canonical: `companyName`, `companyNameLocal`, `formerName`, `entityKind`, `jurisdiction`, `companyNumber`, `incorporationDate`, `registeredOffice`, `authorizedCapital`, `issuedCapital`, `parValue`, `shareClass`, `directorName`, `shareholderName`, `shareholderShares`, `companySecretary`, `registeredAgent`.
  - `custom(String)` for anything else the model finds worth keeping.
  - List-like facts (directors, shareholders, share classes) are repeated entries with the same key; there is no nested structure in V1.
- `ProfileField`: `id` (UUID), `key`, `value` (String), `sourceDocument` (String, file name), `sourceSnippet` (String, verbatim line or sentence containing the value), `snippetVerified` (Bool, true when the snippet was located verbatim in the imported source text), `confidence` (Double 0 through 1), `userEdited` (Bool).
- `CompanyProfile`: `label` (String, matter label), `fields` ([ProfileField]), `sourceDocuments` ([String]), `createdAtISO8601` (String, supplied by the caller per the purity rule), `incomplete` (Bool, true when any extraction segment was truncated; mirrors the LJE-001 posture).
- `BlankLocation`: enum, either `textSpan(start: Int, end: Int)` (UTF-16 offsets into the imported text, NSRange semantics) or `acroFormField(name: String)`.
- `Blank`: `id` (UUID), `location`, `label` (String, for example the bracket contents or the AcroForm field name), `context` (String, surrounding text window), `proposedFieldID` (UUID?), `proposedValue` (String?, defaults to the canonical field value; may be a format adaptation), `status` (`proposed`, `confirmed`, `rejected`, `unmatched`).
- `FillReport`: `outputURL`, `filledCount` (Int), `skipped` ([SkippedBlank]) where `SkippedBlank` carries the blank label, location description, and a reason string. The report never contains filled values, so the sidecar leaks no PII.

## 4. Stage 1: profile extraction

New file `macos/LDACore/Sources/LDACore/Engine/ProfileExtractor.swift`.

- Input: one or more source URLs. Import goes through the existing import path used by the anonymize flow (PdfImporter with PdfOCRImporter fallback, DocxImporter, TextDocumentIO), so scanned certificates work without new code.
- Long sources (articles can run 50+ pages) are chunked with the existing `Chunker`.
- Each chunk runs a new profile-extraction prompt: a new `PromptKind` case in `PromptStore`, bilingual (English and Chinese source documents both supported), JSON-only output contract, parsed with the same defensive style as `EntityJSONParser`. The model returns an array of `{key, value, snippet, confidence}` objects; unknown keys land in `custom`.
- Snippet grounding: `sourceSnippet` must be located verbatim in the imported source text (EntityLocator-style). When the model's snippet cannot be located, the field is kept but flagged unverified and its confidence is capped below the verified floor, so the review UI visibly demotes it.
- The completer is injected behind the existing `TextCompleter` protocol, so ProfileExtractor is unit-testable without the GGUF model. In production it is the same `LLMEngine` instance the anonymize flow uses (the engine layer keeps owning the thinking-off directive).
- Merging across chunks and across documents: entries dedupe by key plus normalized value (case folding, whitespace collapse). For single-valued keys (everything except `formerName`, `shareClass`, `directorName`, `shareholderName`, `shareholderShares`, `custom`), differing values become a flagged conflict: both entries are kept and the profile review UI requires an explicit pick before save. Conflict state is derived at review time (a single-valued key holding more than one distinct normalized value), not stored, so the `.ldaprofile` schema needs no extra field.
- Truncated completions follow the existing incomplete-segment pattern: retry with a larger cap, then split, and if still truncated the profile is marked `incomplete` and the UI and CLI surface a warning that fields may be missing. An incomplete profile is still usable.
- Deterministic assists are optional hardening, not load-bearing: where `DeterministicEngine` validates a structured value (for example a USCC checksum), agreement raises confidence.

## 5. Stage 2: blank detection

New file `macos/LDACore/Sources/LDACore/Engine/BlankDetector.swift`. Fully deterministic, no model involvement.

DOCX and the text it imports to (offsets are UTF-16 into the DocxImporter text, the same convention DocxRedactor consumes):

- Bracketed labels: `[Company Name]`, `[insert date of incorporation]`, `[TBD]`, `[●]`, `[•]`, `[___]`. Pattern family: a bracket pair on one line whose contents are at most roughly 60 characters; the contents become the label.
- Underscore runs: two or more consecutive underscores. Two is deliberate so the year stub in "this ___ day of ___, 20__" and blanks like "Exhibit __" are caught; underscores inside identifiers are not a realistic concern in legal drafts, and review makes residual false positives cheap.
- Bare dot placeholders: a run of one or more `●` or `•` characters outside brackets, a common unlabeled blank in legal drafts.
- Handlebars: `{{field_name}}`.
- Merge-field guillemets: `«FieldName»`.
- Each match produces a `Blank` with the label (empty for bare underscore runs and dot placeholders) and a context window of roughly 240 characters around the match.
- False positives (brackets used for cross-references or optional language) are acceptable: nothing fills without review, the matcher may answer "none", and the lawyer rejects with one keystroke.

AcroForm PDFs:

- Enumerate widget annotations via PDFKit. V1 considers text-type widgets only. The blank label is the field name (plus tooltip text when present); context is nearby page text when cheaply available.
- Checkbox, radio, and choice widgets are collected and listed in the fill report as manual items, never auto-filled.

## 6. Stage 3: matching, review, apply

New file `macos/LDACore/Sources/LDACore/Engine/FillPlanner.swift`.

Matching, deterministic first:

- Normalize the blank label (case fold, trim, strip filler words like "insert", "the", "name of") and look it up in a synonym table mapping label phrases to `ProfileFieldKey`. Examples: "company name", "name of company", "corporate name", "公司名称" map to `companyName`; "date of incorporation", "incorporation date", "成立日期" map to `incorporationDate`; "registered office", "registered address", "注册地址" map to `registeredOffice`. The table ships as code with the prompt-store-style expectation that it grows over time.
- Only unlabeled blanks (underscores, dot placeholders) and labels the table misses go to the model: the prompt carries the blank context plus the profile catalog (keys and values; everything stays on-device) and returns a field key or "none", optionally with a format-adapted value. This lets "this ___ day of ___, 20__" come back as three part-fills ("10th", "June", "26") derived from `incorporationDate` or a date the context implies.
- The proposed value defaults to the profile's canonical value. A format adaptation never replaces the canonical value silently; review shows both.

Review:

- Counsel's Fill mode reuses the review interaction pattern: document pane with blank highlighting, sidebar list, keyboard-first accept and reject, and a field picker to repoint a blank (needed when several entries share a key, for example multiple directors).
- Ambiguous matches (several plausible fields) arrive as `proposed` with the picker pre-opened rather than silently chosen.

Apply:

- DOCX: confirmed fills become `Replacement` values fed through the existing run-preserving DocxRedactor machinery via a thin `DocxFiller` wrapper (`macos/LDACore/Sources/LDACore/IO/DocxFiller.swift`). Formatting and runs survive exactly as they do for redaction. Output file name pattern: `<name> (filled).docx`.
- AcroForm: confirmed values are written to `widgetStringValue` on the matching widget and the document is saved to `<name> (filled).pdf`. The original file is never modified.
- A `FillReport` (value-free) is returned to the caller and shown in the UI; CLI prints it as JSON.

## 7. Persistence and privacy

- `.ldaprofile` reuses the MappingStore container: AES-GCM, versioned binary container, `.passphrase` (PBKDF2-HMAC-SHA256, 200k+ iterations, random salt) or `.keychain` protection. The container logic is factored out of MappingStore into a small shared `EncryptedContainer` so MappingStore and the new ProfileStore (`macos/LDACore/Sources/LDACore/Security/ProfileStore.swift`) share one implementation instead of duplicating it. MappingStore's on-disk format must remain readable (same magic, version, layout) after the refactor.
- The profile is real PII and never touches disk in plaintext, including temp files.
- Extraction and matching run entirely on-device. The sandboxed app keeps no network entitlement; this feature adds no network code path.
- The filled output document intentionally contains real data; that is the product. The fill report stays value-free.

## 8. Surfaces

- Facade: `LDAService` gains `extractProfile(sources:protection:createdAtISO8601:...)`, `planFill(target:profile:)`, and `applyFill(plan:target:profile:to:)`, keeping the facade the single entry point for every edge. Heavy work stays off the main thread in the UI exactly as the existing flows do.
- Counsel UI: a Fill mode in `AppShell` with two screens, profile builder (extract, review fields, resolve conflicts, save and load `.ldaprofile`) and fill review (open target, walk blanks, apply). View-model logic lives in a testable `FillModel` beside `ReviewModel`.
- CLI (final phase, cuttable): `lda extract-profile --out matter.ldaprofile cert.pdf articles.pdf` and a two-step `lda fill --profile matter.ldaprofile --input draft.docx --plan` (prints proposed fills to stdout, persists nothing) then `... --apply` (applies the previously printed plan deterministically). The two-step flow is how review-first translates to a non-interactive edge.
- MCP (final phase, cuttable): `extract_profile` and `fill` tools mirroring the CLI semantics.

## 9. Error handling

- Unreadable source, or OCR yielding no text: error naming the failing document; other sources still contribute.
- Model truncation during extraction: profile marked `incomplete`, warning surfaced (UI banner, CLI JSON field).
- Conflicting single-valued fields: kept and flagged; saving the profile requires resolving the conflict; never silently chosen.
- No blanks found in the target: a clear empty-state message, not an error.
- Secured PDF that refuses modification: per-file error at apply time.
- Unmatched blanks: left untouched, listed in the report with reason "no matching field".
- AcroForm field whose widget disappears between plan and apply (file changed on disk): apply aborts with a stale-target error rather than guessing.

## 10. Testing

Tests first, mirroring the existing suites under `macos/LDACore/Tests/LDACoreTests/`:

- `BlankDetectorTests`: every supported convention, label extraction, context windows, false-positive guards (cross-reference brackets are still detected but match "none" downstream; bare punctuation is not a blank).
- `ProfileExtractorTests`: fake `TextCompleter` (the LLMExtractorTests pattern); chunk and document merging, dedupe, conflict flagging, truncation marking, malformed JSON salvage.
- `FillPlannerTests`: synonym-table hits including Chinese labels, normalization, model fallback via fake completer, ambiguity producing a picker state, "none" answers.
- `DocxFillTests`: round-trip on the DocxIOTests fixture pattern, multi-run blanks, formatting preservation, output never overwriting input.
- `AcroFormFillTests`: programmatically built fixture PDF with text widgets plus one checkbox; text fills land, checkbox is reported manual, original untouched.
- `ProfileStoreTests`: encrypt and decrypt round-trip, wrong passphrase fails, tampered container fails (mirroring EncryptedStoreTests), and MappingStore still reads a pre-refactor fixture container.
- `FillModelTests`: review state machine, accept and reject, repointing, apply gating (only confirmed blanks fill).
- One live GGUF end-to-end test behind the existing fixture skip-guard pattern.

## 11. Implementation phasing (preview for the plan)

1. Domain types, `EncryptedContainer` refactor, `ProfileStore` (plus MappingStore compatibility tests).
2. `BlankDetector`, `DocxFiller`, AcroForm filler: the deterministic spine, fully testable without the model.
3. `ProfileExtractor` and `FillPlanner` prompts, parsing, merging, conflicts.
4. Facade operations, `FillModel`, Counsel Fill mode UI.
5. CLI and MCP wrappers, packaging notes, README.

Branch mechanics: implementation branches off `feat/lda-macos-core` (the worktree convention in the project memory), not off `main`; this spec lives on the session branch and travels with the implementation PR or merge.
