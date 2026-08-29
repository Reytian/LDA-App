# LDACore

LDACore is the headless Swift core of LDA.app, a native macOS legal-document
anonymizer that runs fully offline and on-device.

This package contains no UI. It is the single shared core beneath three later
faces: a SwiftUI app, a CLI, and an MCP stdio server. Document processing is
entirely on-device; the app reaches the network only to download a detection
model the user has asked for, and this core is not part of that path.

## System requirements

**Minimum: a Mac with 16 GB of memory.** LDA runs its detection model on your
machine, and the model has to fit in memory alongside whatever else you have
open. Below 16 GB there is no configuration that both detects names reliably and
leaves room for a word processor and a browser, so 16 GB is the floor rather
than a recommendation.

What each detection level needs, measured on an Apple M4:

| Level | Model | Download | Peak memory | Mac needed | Per agreement |
|---|---|---|---|---|---|
| Patterns only | none | none | none | any | instant |
| Quick | Qwen3.5-4B | built in | 3.1 GB | **16 GB** | about 55 s |
| Balanced | gemma-4-12b | 7.1 GB | 8.5 GB | 24 GB | about 2 min |
| Most thorough | Qwen3.8-27B | 13.2 GB | 12.2 GB | 24 GB | about 4.5 min |

Quick ships inside the app, so a 16 GB Mac works out of the box with no
download. Balanced and Most thorough are downloaded from Model Management in
Settings. LDA will not offer you a level your Mac cannot run.

Also required: macOS 14 or later, and Apple silicon.

## What lives here

- `Sources/LDACore/Domain/` holds the frozen public domain types (entity types,
  spans, mappings, token grammar, role labels). These are the contract that
  every engine and every face agrees on.
- `Sources/LDACore/Engine/` holds the pure, synchronous engines:
  DeterministicEngine, SpanMerger, Tokenizer, Restorer, and PromptStore. The LLM
  engine is built in a later phase and is not part of this package.

## Design

- Hybrid detection: deterministic regex plus checksum for structured PII
  (EMAIL, PHONE, BANK_ACCOUNT, USCC, DATE, AMOUNT, NATIONAL_ID), and an LLM (in a
  later phase) for fuzzy entities (PERSON, COMPANY, ADDRESS).
- On a type conflict, deterministic wins.
- Role labels (Buyer, Seller, 甲方, 乙方, and the rest) are never redacted.
- Restore is pure deterministic token substitution plus an orphan-token guard.
- Token grammar: `{TYPE_N}` where `TYPE` matches `[A-Z][A-Z0-9]*` and `N` is a
  positive integer. Canonical detection regex: `\{[A-Z][A-Z0-9]*_\d+\}`.

All offsets in the public API are UTF-16 code-unit offsets, NSRange-compatible,
because the deterministic engine runs `NSRegularExpression` over the text as
`NSString`.

The full design specification lives at
`docs/superpowers/specs/2026-06-06-lda-app-design.md` in the repo root.

## Fill from profile

Fill from profile lets you build a structured company profile from source
documents (articles of incorporation, certificates, company registry printouts)
and then use that profile to auto-fill blanks in draft agreements or form PDFs,
without retyping facts by hand.

### CLI commands

**Build and save a profile from source documents:**

```
lda extract-profile --label "Meridian" --out meridian.ldaprofile \
    --model /path/to/lda-v2-Q4_K_M.gguf certificate.pdf articles.docx
```

**Preview the fill plan without writing anything:**

```
lda fill --profile meridian.ldaprofile --input agreement.docx --plan
```

**Apply the fill and write the filled document:**

```
lda fill --profile meridian.ldaprofile --input agreement.docx \
    --apply --output-dir ./filled/
```

### Format and posture

Profiles are saved as `.ldaprofile` files: AES-GCM encrypted, versioned
containers. The format is the same as the mapping files used by anonymize
and restore; no plaintext profile data is ever written to disk.

The fill pipeline is review-first by design. `--plan` prints the proposed
fills to stdout so you can inspect them before committing. `--apply`
re-plans from the current profile state and promotes all proposed blanks
with a value to confirmed, then writes the output; a warning is printed
when the target has changed since you ran `--plan`.

### Portfolio library

The portfolio library is a persistent, encrypted store of client portfolios
on your Mac. You can browse all saved portfolios, create a new one from source
documents or from scratch, edit fields, add custom fields, fill documents
directly from a saved portfolio, export a portfolio to a portable `.ldaprofile`
file, import a portfolio shared by a colleague, and delete portfolios you no
longer need.

**Three portfolio kinds** control which fact set the model is prompted for:

| Kind | Field set |
|------|-----------|
| `company` | Corporate fields: name, company number, incorporation date, registered office, directors, shareholders, and similar (19 fields). |
| `individual` | Personal fields: full name, date of birth, nationality, passport number, national ID, residential address, email, phone (8 fields). |
| `general` | The combined set of both company and individual fields. |

**Library location:** portfolios are stored in
`~/Library/Application Support/LDA/Portfolios/` as AES-GCM encrypted
`.ldaprofile` files. The decryption key is held in the macOS Keychain under
the service `ai.openclaw.lda.profilekey`. No plaintext portfolio data is
ever written to disk.

**CLI commands:**

List all portfolios in the library (value-free JSON, no field values):

```
lda portfolio list
```

Show metadata and field keys for one portfolio (by name or UUID):

```
lda portfolio show "John Whitmore"
lda portfolio show 3F8A9C12-...
```

Build a profile from source documents and save it to the library via a
`.ldaprofile` file that you can import:

```
lda extract-profile --label "John Whitmore" --kind individual \
    --model /path/to/lda-v2-Q4_K_M.gguf \
    --out whitmore.ldaprofile identity-letter.pdf passport-scan.pdf
```

Fill a document from a saved library portfolio:

```
lda fill --portfolio "Meridian Pacific" --input agreement.docx \
    --plan
lda fill --portfolio "Meridian Pacific" --input agreement.docx \
    --apply --output-dir ./filled/
```

### V1 limits

- Supported fill targets: `.docx` (text-span blanks) and `.pdf` (AcroForm
  text widgets only). Flat PDFs with no form fields are accepted and produce
  an empty plan rather than an error.
- Checkbox, radio, and choice widgets are listed as manual items in the
  report; they are not auto-filled.
- One profile per run. Multi-party fills require separate runs.

## House rules

All code comments, docstrings, and strings are in English. No em-dash and no
en-dash-as-separator anywhere.
