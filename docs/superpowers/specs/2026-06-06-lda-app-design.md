# LDA.app Design Specification

Date: 2026-06-06
Status: Frozen design baseline for the native macOS rewrite.

## 1. Product Summary

LDA.app is a native macOS legal-document anonymizer. It runs fully offline and
on-device. The target user is a lawyer who:

1. Opens a `.docx`, PDF, or plain-text document.
2. Sees PII detected and highlighted by type.
3. Reviews each candidate (accept or reject) on a tokenized view of the text.
4. Exports a redacted document.
5. Later deterministically restores the real values into the edited document.

No network access is required or permitted at any point. The app ships with no
network entitlement, and every face (app, CLI, MCP server) preserves that
offline posture.

## 2. Locked Architecture

One headless Swift core, `LDACore` (the package this spec scaffolds), with three
faces built later on top of it:

- SwiftUI app (the primary face).
- Command-line interface (CLI).
- MCP server (stdio transport).

The core is pure, synchronous where possible, and Sendable-clean. It contains no
UI, no I/O side effects in its pure functions, and no clock reads inside pure
functions (callers supply timestamps).

### 2.1 Hybrid Detection Engine

Detection is hybrid:

- DETERMINISTIC (regex plus checksum) for STRUCTURED PII:
  EMAIL, PHONE, BANK_ACCOUNT, USCC (统一社会信用代码), DATE, AMOUNT, and
  NATIONAL_ID (Chinese 身份证号, 18 digits, validated by the ISO-7064 mod-11-2
  checksum).
- LLM (built later, NOT in this package) for FUZZY entities:
  PERSON, COMPANY, ADDRESS.

### 2.2 Conflict Resolution

On a type conflict, DETERMINISTIC WINS. A checksum-valid 身份证 is NATIONAL_ID,
never DATE and never BANK_ACCOUNT. Deterministic, validated structured PII is
assigned a high priority so it wins overlap resolution in the SpanMerger.

### 2.3 Role Labels Are Never Redacted

Role labels are contract terms of art, not PII. They are NEVER redacted.
Examples: 甲方, 乙方, 转让方, 受让方, Buyer, Seller, Lessor, Lessee, the Company,
Disclosing Party, and the full set enumerated in `RoleLabels.all`. The matching
is case-insensitive and whitespace-trimmed.

### 2.4 Restore Is Pure Deterministic

Tokens are unique, opaque placeholders such as `{PERSON_1}`. Restore is a global
token to value substitution, plus an ORPHAN-TOKEN GUARD that detects leftover or
broken tokens and warns. There is NO fuzzy matching, NO position window, and NO
context matching at restore time. This is a deliberate simplification over the
prior Python implementation, which used position-window plus context plus
canonical fallback. The native core trades that complexity for determinism: a
token either maps to a value or it is an orphan.

### 2.5 Token Grammar

A token is literally `{TYPE_N}` where:

- `TYPE` matches `[A-Z][A-Z0-9]*`.
- `N` is a positive integer.

Canonical detection regex (keep emit and restore in sync with this):

```
\{[A-Z][A-Z0-9]*_\d+\}
```

`TokenGrammar.sanitizeType` slugifies a raw type string into a conforming TYPE:
uppercase, strip everything that is not `A-Z0-9`, empty becomes `UNKNOWN`, and a
leading non-letter is prefixed with `X`.

### 2.6 House Rules

All code comments, docstrings, and string literals are in English. No em-dash
and no en-dash-as-separator appears anywhere in code, prose, or document
templates.

## 3. The Eight Isolated Units

Each unit is a single responsibility with a narrow public surface. They compose
but do not reach into one another's internals.

1. DeterministicEngine
   - Regex plus checksum detection of structured PII.
   - `detect(_ text:) -> [Span]`. Pure and synchronous.
   - Owns the EMAIL, PHONE, BANK_ACCOUNT, USCC, DATE, AMOUNT, and NATIONAL_ID
     patterns and the ISO-7064 mod-11-2 身份证 validator.

2. LLMEngine
   - Built later. Drives the local model for PERSON, COMPANY, ADDRESS.
   - Produces `[Span]` with `source = .llm`.
   - Implements the three-tier scan (see Section 4).

3. SpanMerger
   - `merge(deterministic:, llm:) -> [Span]`.
   - Resolves overlaps. Deterministic wins on conflict. Higher priority wins,
     then longer span, then earliest start as the final tie-break.
   - Drops role-label spans via `RoleLabels`.

4. Tokenizer / Mapper
   - `tokenize(text:, spans:, sourceFile:, createdAtISO8601:) -> TokenizeResult`.
   - Mints one opaque token per distinct surface value, emits the tokenized
     text, and builds the `Mapping`. Pure: the caller supplies the timestamp.

5. Restorer
   - `restore(text:, mapping:) -> RestoreResult`.
   - Global token to value substitution plus the orphan guard.

6. DocumentIO
   - Reads and writes `.docx`, plain text, and PDF (born-digital text layer and
     scanned via Apple Vision OCR).
   - PDF round-trip is via a generated `.docx` or text companion, not an
     in-place PDF rewrite (see Section 5).

7. MappingStore
   - Persists the `Mapping` as an encrypted sidecar (see Section 6).

8. PromptStore
   - Holds editable Pass-1 and Pass-2 prompt bodies with restore-to-default.

### 3.1 Matter (Shared Entity Map Across Files)

A Matter is the shared entity map spanning multiple files in one engagement. It
lets `{PERSON_1}` mean the same person across every document in the matter, so a
counterparty named once is tokenized consistently across the contract, the
schedules, and the side letters. The Matter owns the cross-file token namespace
and seeds the Tokenizer so token numbering stays stable across files.

## 4. The Three-Tier Engine

Tier 0: DETERMINISTIC FULL SCAN.
  - `DeterministicEngine.detect` over the entire text.
  - Catches every structured PII occurrence with checksum validation.
  - Always runs, even when the LLM is unavailable.

Tier 1: LLM PASS-1 ANCHORED MAP BUILD.
  - Runs on high-density sections (definitions, notice clauses, signature
    blocks) to build the canonical entity and alias map.
  - Establishes which surface forms refer to the same entity before the full
    scan begins.

Tier 2: LLM PASS-2 FULL-COVERAGE CHUNKED SCAN.
  - FULL coverage of the document, chunked with overlap.
  - Chunk size approximately 400 to 512 tokens.
  - Overlap approximately 15 to 20 percent so entities near chunk boundaries are
    not lost.
  - Dual mode: a CONSTRAINED pass that looks for the anchored entities from
    Tier 1, plus a DISCOVERY pass that surfaces new entities.
  - Bounded concurrency of 2 to 4 in-flight chunks to keep memory and the local
    model load predictable.

Deterministic results (Tier 0) and LLM results (Tiers 1 and 2) are unified by
the SpanMerger, where deterministic always wins on conflict.

## 5. V1 Scope: Document I/O

V1 supports three input families:

- `.docx`.
- Plain text.
- PDF, in two sub-cases:
  - Born-digital with a real text layer.
  - Scanned, recovered via Apple Vision OCR.

PDF round-trip uses a generated `.docx` or text companion rather than rewriting
the PDF in place. The reasoning: in-place PDF rewriting of a redacted and edited
document is fragile and risks leaving recoverable PII in the PDF object graph.
Producing a clean companion document is safer and keeps the restore step
operating on a well-structured text or `.docx` surface.

Restore operates as pure deterministic token substitution plus the orphan guard,
regardless of the original source format.

## 6. Mapping Security

The mapping is the crown jewel: it holds the real values behind every token.

- Stored as an AES-GCM encrypted sidecar file next to the redacted document.
- The encryption key is wrapped in the macOS Keychain.
- An optional user passphrase adds a second factor on top of the Keychain-wrapped
  key.
- The sidecar never contains plaintext PII at rest.

## 7. UI Direction: "Counsel"

A light, paper-forward visual direction that reads like a legal document rather
than a developer tool.

- Light theme, paper-forward surfaces.
- Document body in a serif typeface; chrome in SF Pro.
- One ink-blue accent color.
- A muted, low-chroma semantic entity palette. Entity types are distinguished by
  underline rules and dots rather than loud fills, so the tokenized document
  still reads as a document.
- `NavigationSplitView` layout.
- Keyboard-first review: J and K to move between candidates, A to accept, R to
  reject.

## 8. CLI and MCP Faces

The CLI and the MCP stdio server are thin faces over `LDACore`. Both preserve
the no-network-entitlement offline posture. The MCP server speaks stdio only.
Neither face introduces network access, and neither duplicates core logic; they
marshal arguments into the core and format the core's results back out.

## 9. Build Order (Six Phases)

Phase 0: Model GGUF.
  Acquire and pin the local model artifact for the LLM engine.

Phase 1: Deterministic core (THIS package).
  `LDACore` with frozen domain types and the deterministic engine, SpanMerger,
  Tokenizer, Restorer, and PromptStore.

Phase 2: LLM engine.
  The three-tier scan, chunking, and the local model driver.

Phase 3: DocumentIO.
  `.docx`, text, and PDF (text layer plus Vision OCR), with the PDF companion
  round-trip.

Phase 4: MappingStore.
  AES-GCM sidecar, Keychain key wrapping, optional passphrase.

Phase 5a: CLI plus MCP.
  The two headless faces.

Phase 5b: SwiftUI.
  The "Counsel" app face.

Phase 6: Shell plus notarize.
  Packaging, signing, and notarization for distribution.

## 10. Fidelity Notes Ported From The Python Prototype

The native core ports concepts (not code) from the existing Python prototype in
`core/anonymizer.py`, `core/deanonymizer.py`, and `core/prompts.py`:

- The `sanitizeType` rules match the Python `_sanitize_type`: uppercase, strip
  non `A-Z0-9`, empty becomes `UNKNOWN`, leading non-letter prefixed with `X`.
- The token detection regex `\{[A-Z][A-Z0-9]*_\d+\}` is identical to the Python
  `PLACEHOLDER_REGEX`, and emit and restore stay in sync with it.
- One token per distinct surface value (the Python one-string-one-original
  invariant) carries over.
- The Python restore used position window, context similarity, and canonical
  fallback. The native restore deliberately drops all three in favor of pure
  token substitution plus an orphan guard, because opaque unique tokens make the
  ambiguity those steps resolved impossible by construction.
