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
  (EMAIL, PHONE, BANK_ACCOUNT, USCC, DATE, AMOUNT, NATIONAL_ID, CASE_NUMBER,
  LICENSE_PLATE, WECHAT_ID, URL), and an LLM (in a
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

## Security posture

### At rest

Everything the app persists goes through `EncryptedContainer`: mapping
sidecars, client mappings, profiles, the portfolio library, session records,
and the audit log. Each store has its own magic bytes and its own Keychain
service, so a container of one kind can never be opened as another.

Container format version 2:

- AES-256-GCM via CryptoKit.
- The **entire plaintext header** (magic, version, protection tag, salt length,
  salt, iteration count) is bound as additional authenticated data, so editing
  any header byte makes the tag fail rather than merely failing a downstream
  sanity check.
- The **PBKDF2 iteration count is stored in the header**. New containers use
  600,000 iterations (current OWASP guidance for PBKDF2-HMAC-SHA256); the count
  can be raised again later without a format change.
- Version 1 containers, written before either change, still open: their
  implicit 200,000 iterations and absence of AAD are selected by the version
  byte rather than guessed at with a retry.

Keys held in the Keychain use `WhenUnlockedThisDeviceOnly`. In the GUI app they
are additionally behind a user-presence access control, so retrieval prompts
for Touch ID with the login password as the system fallback. The in-process key
cache that keeps this to about one prompt per key is **bounded**: at most 16
keys, each expiring 15 minutes after its last use, and the whole cache is
purged when the Keychain policy changes.

If a pre-existing unprotected key cannot be upgraded to user presence, which
happens on a locally signed Developer ID build with no provisioning profile,
the app **says so** in the status bar and in Settings rather than continuing to
imply a Touch ID gate that is not there.

### Audit trail

The GUI app keeps a local, encrypted, append-only log of security-relevant
operations at
`~/Library/Application Support/LDA/security-events.ldaaudit`: container seals
and opens, Keychain key creation and retrieval, denied Touch ID prompts, failed
user-presence upgrades, and key-cache purges.

It records a timestamp, the operation, the store kind, success or failure, and
a truncated digest of the Keychain account. It records **no** document text, no
entity values, no file paths, and no client or matter labels (account names
embed client labels, which is why only their digest is stored). The log is off
by default; headless surfaces (CLI, MCP) do not write one.

### Import ceilings

Applied by every importer, not only by the service facade, so a caller that
reaches for an importer directly hits the same limit:

| Limit | Value |
|-------|-------|
| Single document | 200 MB |
| Archive uncompressed payload | 500 MB |
| Archive entries | 1,000 |

Archive limits are spent against each entry's **declared** uncompressed size,
before anything is written, so a zip bomb is refused rather than unpacked.

### Temporary files

Expanding a `.zip` writes the user's original, un-redacted documents into a
temporary directory. Those expansions are tracked and deleted at a session
boundary: the end of a CLI command, the end of an MCP request, an emptied
document tray, or window close. A rejected or failed expansion is cleaned up
immediately.

### Clipboard

The companion's **Restore** puts de-anonymized text on the system clipboard.
That write is marked concealed and transient (the nspasteboard.org convention
that clipboard managers read to skip archiving a secret) and clears itself
after 30 seconds, but only if nothing else has been copied since, so it never
destroys the user's own clipboard. The user is told the window in the same
message that reports the restore.

Note that concealed and transient are a convention honored by well-behaved
apps, not an OS guarantee. Pasting promptly is still the right habit.

### Prompt injection

Document text reaches the model verbatim, so a document can try to address the
model directly. The classic payload tells it to report no entities, which in
this app means PII passing through as clean. Untrusted text is therefore fenced
with explicit begin and end markers, any copy of those markers inside the text
is neutralized so a document cannot close its own fence, and the task is
restated **after** the document to counter recency. The fine-tuned v2
instruction prefix is preserved byte for byte.

## Running the tests

```
swift test --scratch-path ~/Developer/lda-build
```

The `--scratch-path` matters on a repo inside iCloud Drive, which evicts files
mid-build. It isolates BUILD products only.

### Concurrent runs

The suite is hermetic: two runs from two worktrees at the same time report the
same numbers. That is not free, because `--scratch-path` does not isolate the
three things a test run shares with every other process on the machine.

- **The Keychain** is per user. `Tests/LDACoreTests/TestNamespace.swift` gives
  each test PROCESS a token (pid plus a random component) and derives every
  Keychain account, UserDefaults suite, and store base key from it, so two runs
  cannot name the same item. Delete only what the test itself minted. Accounts
  that are shared by design (the records key, the audit keys, the portfolio
  index key) may be read but must never be deleted: deleting a shared legacy
  account also removes its `.userpresence` variant, which is the item Touch ID
  unlocks.
- **The UserDefaults database** is per user. Tests use private suites from
  `TestNamespace.defaults(_:)`, never `UserDefaults.standard`. Production types
  that read the standard domain expose a seam for this (`SessionModel`'s
  `scopeDefaults` and `legacyDefaults`). `TestNamespace` also erases every suite
  it minted when the test bundle finishes, because
  `removePersistentDomain(forName:)` does **not** erase one: measured on macOS
  26, it clears the value in memory and leaves the old value in
  `~/Library/Preferences`. For the vocabulary stores that value is a sealed blob
  of learned party names whose vault key is also on the machine, so the sweep
  removes the domain and then unlinks the plist.
- **The GPU** is per machine. The detection model is 2.7 GB in unified memory:
  one process fits, two do not, and the second allocation does not throw.
  llama.cpp keeps decoding and returns garbage, so the failure shows up as a
  content assertion rather than an error. Live-model tests therefore run inside
  `LiveModelTestSupport.withLiveModel`, which holds a machine-wide advisory lock
  while the model is resident.

`TestHermeticityTests` enforces all three by reading the test sources, the way
`NetworkChokepointTests` reads `Sources/`. When it fails, route the name through
`TestNamespace` rather than adding an allowlist entry.

## Known limitations

### CLI passphrase exposure

`--passphrase` on any `lda` subcommand takes its value from the command line,
where it is visible to `ps` for the lifetime of the process and is written to
your shell history. This affects the CLI only; the GUI app never puts a
passphrase on a command line.

Prefer omitting `--passphrase` entirely. Without it the store is protected by a
per-document key held in the macOS Keychain, which is both safer and less to
remember. Use `--passphrase` only when you specifically need a portable file
that opens on another Mac, and in that case prefer a shell that does not record
the command (a leading space with `HISTCONTROL=ignorespace` in bash, or
`setopt HIST_IGNORE_SPACE` in zsh).

A Keychain-only path that reads the passphrase from an interactive prompt
instead of a flag is planned; the four `TODO` markers in `Sources/LDACLI/`
track it.

### Keychain accounts are per edge

The CLI and the MCP server derive their per-document Keychain accounts under
different namespaces (`lda-<mapping base>` vs
`ai.openclaw.lda.mcp.<redacted handle>`), so a sidecar protected by the
Keychain on one edge does not restore on the other. This is deliberate
isolation, not a bug, but it surprises people: anonymize and restore through
the same edge, or pass `--passphrase` when a sidecar must travel between tools
or machines. On the MCP side the account embeds only the opaque artifact
handle, never a document name.

### Other limitations

- **arm64 only.** `llama.xcframework` is built for Apple silicon; there is no
  Intel Mac support.
- **MCP context boundary.** Everything an MCP tool returns enters the model
  context of the agent host and leaves the machine, and file paths are
  themselves PII (legal folders are named after the parties). The advertised
  tools therefore operate on opaque vault handles: the human stages documents
  with `lda vault stage <path>`, and the tools return handles, redacted text
  (`read_redacted` only), and aggregate counts. No original text, no detected
  entity values, no filenames, and no paths cross the tool surface, in results
  or in error messages. `attest` reports the posture, including byte counters
  for what the session has returned. The vault lives at
  `~/Library/Application Support/LDA/Vault` (override with `LDA_VAULT_DIR` at
  launch); exports land only in the vault's own `outbox/`. The old path-taking
  core tools are removed; `extract_profile`, `fill`, and the portfolio tools
  are refused unless the server is launched with
  `LDA_MCP_LEGACY_PATH_TOOLS=1`. Vault contents are plaintext on disk in this
  phase (`attest` says so honestly); encryption at rest and XPC key holding
  are the next phases.
- **MCP host trust.** The gated legacy tools read and write only inside the
  user's home directory and the system temporary directory. Set
  `LDA_MCP_ALLOWED_ROOTS` (colon separated) when launching the server to allow
  additional locations. This is an environment variable set by whoever launches
  the server, not a value a request can supply: a policy a request can widen is
  not a policy. GGUF model paths (the one path argument the handle-first tools
  still accept) are held to the same allow-list, widened by one directory: the
  app bundle's `Resources`, where a distributed build ships its model. A model
  anywhere else requires `LDA_MCP_ALLOWED_ROOTS`, so a prompt-steered host
  cannot stage a malicious model in some other writable location and point
  llama.cpp at it. The launcher itself stays trusted: it controls the
  environment, the binary, and the bundled model.
- **Review PDF coverage.** For PDF input, a value that is tokenized in the edit
  surface but whose position could not be established on the page is counted in
  `unboxedTokenCount` rather than being given an invented box. A non-zero count
  means the review PDF still shows those values and must be surfaced to the
  user.

## House rules

All code comments, docstrings, and strings are in English. No em-dash and no
en-dash-as-separator anywhere.
