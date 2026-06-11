# Client Portfolio Portal: design spec

Date: 2026-06-11
Status: approved by user (design conversation, this session)
Target codebase: native macOS app ("Counsel") at `macos/LDACore` on branch `feat/lda-macos-core` (builds on the fill-from-profile feature merged at 3db2851; its spec is `2026-06-10-fill-from-profile-design.md`)
House rules: all code comments and strings in English; no em-dash and no en-dash-as-separator anywhere, including this document.

## 1. Problem and goal

The fill-from-profile feature extracts a company profile from incorporation documents and fills blanks from it. Two limitations remain. First, extraction is tuned to incorporation documents and a company-centric schema; real matters also revolve around individuals and arbitrary document sets. Second, profiles are loose `.ldaprofile` files the user manages in Finder; there is no place in the app to browse, create, edit, or delete them, no way to create one from scratch without source documents, and no way to add a field the model did not extract.

The feature: a client portfolio portal. The app owns an encrypted portfolio library; the portal lists portfolios by name and kind; the user creates portfolios from ANY documents or from scratch, edits them anytime (including adding fields), fills documents from them, and exports or imports `.ldaprofile` files for portability. Private information is entered or extracted once and reused indefinitely, never re-imported per document.

### Goals

- A managed, encrypted portfolio library owned by the app (Application Support, not iCloud-synced), browsable in Counsel without prompts (Keychain-held keys).
- Portfolio kinds: `company`, `individual`, `general`. Each kind brings canonical fields; every kind accepts unlimited custom fields.
- Create from documents (any importable format, via the existing extraction pipeline with a kind-aware prompt) or from scratch (empty editable table).
- Edit anytime: change values, remove fields, ADD fields (canonical for the kind, or custom).
- Fill any DOCX or AcroForm target from any library portfolio (the existing fill flow, unchanged).
- Export a portfolio as `.ldaprofile` (optional passphrase for files leaving the machine); import external `.ldaprofile` files into the library.
- CLI and MCP: read-only portal (`portfolio list`, `portfolio show`, both value-free) and `fill --portfolio <name-or-id>` resolving from the library.
- No client name ever appears in plaintext on disk, including filenames.

### Non-goals (V1 cuts)

- No CLI or MCP portfolio creation or editing.
- No multi-machine sync; portability is manual export/import.
- No edit history or versioning; a save overwrites.
- No linking portfolios to matters, and no merging of two portfolios.
- No changes to the fill engine (BlankDetector, FillPlanner, DocxFiller, AcroFormFiller, applyFill semantics are untouched).
- No master-passphrase mode for the library (Keychain only; passphrase exists at the export boundary).

## 2. User workflow

1. Fill mode opens on the portal: a list of portfolios (label, kind, modified date) read from the encrypted index. No prompts; the index key lives in the Keychain.
2. New Portfolio: pick a kind (Company, Individual, General) and a label, then either "From documents" (add any PDF, DOCX, or TXT sources; the on-device model extracts kind-appropriate facts with provenance, exactly like the existing extract flow) or "From scratch" (empty field table).
3. Edit: the existing field table (value editing, removal, conflict resolution, verified badges, incomplete banner) plus a new Add Field control: choose a canonical key for the portfolio's kind or type a custom field name, then a value. Save writes to the library with no prompt.
4. Fill a document: select a portfolio, open a DOCX or AcroForm PDF target, review blanks, apply. Identical to the shipped flow.
5. Export: choose a destination and optionally a passphrase; the file is a standard `.ldaprofile`. Import: pick an external `.ldaprofile` (Keychain or passphrase protected), and it joins the library under the library's Keychain key.
6. Delete: with confirmation; removes the portfolio file and its index entry.

## 3. Domain changes

- `CompanyProfile` is RENAMED `ClientPortfolio`. The at-rest JSON carries no type name, so every existing `.ldaprofile` loads unchanged. All consumers are in-repo; no compatibility alias is kept.
- `ClientPortfolio` gains:
  - `kind: PortfolioKind` with cases `company`, `individual`, `general` (String raw values). Decoding a legacy JSON without the key defaults to `.company`.
  - `modifiedAtISO8601: String`, caller-supplied per the purity rule. Decoding legacy JSON defaults it to `createdAtISO8601`.
- `PortfolioKind` lives beside it, Codable and Sendable.
- `ProfileFieldKey` gains canonical individual-kind cases: `clientName`, `dateOfBirth`, `nationality`, `passportNumber`, `nationalIDNumber`, `residentialAddress`, `email`, `phone`. Wire format follows the existing rawKey convention; older builds decode unknown keys as `.custom` by design. `email`, `phone`, and `residentialAddress` are meaningful for company kinds too; canonical keys are NOT gated by kind at the type level (kind drives prompts and UI grouping, not type validity).
- `ProfileFieldKey.canonical(for kind: PortfolioKind) -> [ProfileFieldKey]` returns the ordered keys the UI offers and the prompt lists for a kind: company returns the existing seventeen plus `email` and `phone`; individual returns the eight new person keys (which already include `email` and `phone`); general returns the union of both lists.
- Add Field name resolution, pinned: a typed field name resolves through `ProfileFieldKey(rawKey:)` FIRST, so typing "email" yields the canonical `.email` (and therefore matches the synonym table during fill); only names that match no canonical rawKey become `.custom`. The UI shows which one resulted (canonical keys display their displayName).
- List-like keys gain nothing new; all new keys are single-valued except none (a person has one passport number per portfolio in V1; multiple passports land in custom fields).
- Conflict detection (`conflictedKeys`) extends mechanically to the new single-valued keys; derivation stays unstored.

## 4. PortfolioLibrary (new LDACore unit)

`Sources/LDACore/Security/PortfolioLibrary.swift`. One library per machine.

- Location: `FileManager.urls(for: .applicationSupportDirectory)` + `LDA/Portfolios/`. Created on first use. Local, not iCloud-synced.
- Layout: one encrypted portfolio file per portfolio, named `<uuid>.ldaprofile`, EXACTLY the existing `.ldaprofile` container (magic `LDAPROF`, Keychain service `ai.openclaw.lda.profilekey`, library account constant). Filenames are opaque UUIDs so labels never appear in plaintext on disk.
- Index: `index.ldapidx`, a NEW store kind per the EncryptedContainer rule (distinct magic `LDAPIDX`, distinct Keychain service `ai.openclaw.lda.libraryindexkey`, account constant `index`). Contents: `[PortfolioSummary]` where `PortfolioSummary {id: UUID, label: String, kind: PortfolioKind, createdAtISO8601: String, modifiedAtISO8601: String, fieldCount: Int, conflicted: Bool}`. Value-free by construction.
- API (all throwing; timestamps caller-supplied):
  - `list() throws -> [PortfolioSummary]` (sorted by label; decrypts only the index)
  - `create(_ portfolio: ClientPortfolio) throws -> UUID`
  - `load(id: UUID) throws -> ClientPortfolio`
  - `save(_ portfolio: ClientPortfolio, id: UUID) throws` (atomic: write temp file in the library directory, then rename; index updated after the portfolio write succeeds)
  - `delete(id: UUID) throws` (file removed, then index entry)
  - `exportPortfolio(id: UUID, to url: URL, protection: MappingProtection) throws` (re-encrypts with the chosen protection so an exported file behaves like any hand-saved `.ldaprofile`)
  - `importPortfolio(from url: URL, protection: MappingProtection) throws -> UUID` (loads with the supplied protection, assigns a fresh UUID, saves under the library key)
- Keychain account convention, pinned here because the merged code currently disagrees with itself (FillShell uses `url.lastPathComponent` INCLUDING the extension; CLI and MCP use `deletingPathExtension().lastPathComponent`): the standard per-file account is `deletingPathExtension().lastPathComponent`. Saves (UI export, CLI, MCP) always use the standard account. Loads try the standard account first and fall back to the legacy extension-included account so files saved by the pre-portal UI still open. The UI save path is corrected to the standard convention as part of this work. The library's own files do not use per-file accounts at all; they use a single library account constant `library` under the profile service.
- Resilience: `list()` tolerates orphans in both directions: an index entry whose file is missing is dropped from the returned list (and pruned on the next index write). A portfolio file missing from the index is recovered by loading it with the library key: when it decrypts, the entry rejoins the index with its REAL label; when it cannot decrypt, it is surfaced with the placeholder label "Recovered portfolio <short-id>" and behaves as the corrupt-file case in section 8 (unreadable, delete offered). A corrupt index is rebuilt the same way. A corrupt portfolio file affects only that portfolio.
- Concurrency: single-process assumption (the app, CLI, or MCP server runs one at a time on one machine); no cross-process locking in V1. Within the app, library calls happen off the main thread through the model, matching existing conventions.

## 5. Extraction generalization

- `LDAService.extractProfile` gains `kind: PortfolioKind`. The result assembles a `ClientPortfolio` with that kind.
- `PromptStore.defaultProfileSystem` generalizes: "You extract client facts from legal, corporate, and identity documents (certificates, articles, registers, licenses, passports, utility statements, letters)." The allowed-keys sentence is built per kind from `ProfileFieldKey.canonical(for:)` raw keys; every existing rule stays (verbatim value, verbatim snippet, confidence, repeated keys for lists, custom fallback as a single camelCase word, chunk-boundary snippet allowance, return [] when nothing). The prompt builder becomes `profileUser(documentName:chunk:)` unchanged; the system body is produced by a function `profileSystem(for kind: PortfolioKind)` that injects the key list into one editable template (the editable body keeps a `{allowed_keys}` slot). The slot warning is a NEW kind-aware validation entry point (`validateProfileTemplate(_:)` or similar), NOT an extension of the existing `validate(_:)`, which is documented as calibrated for the Chinese pass1/pass2 bodies only. Note: `PromptSnapshot` does not carry the profile body (pre-existing behavior), so template edits do not persist across sessions; this feature does not change that.
- The synonym table gains individual entries with Chinese equivalents: clientName ("client name", "full name", "name of individual", "姓名"), dateOfBirth ("date of birth", "birth date", "dob", "出生日期"), nationality ("nationality", "citizenship", "国籍"), passportNumber ("passport number", "passport no", "护照号码", "护照号"), nationalIDNumber ("id number", "national id", "identity card number", "身份证号码", "身份证号"), residentialAddress ("residential address", "home address", "住址", "住宅地址"), email ("email", "e-mail", "email address", "电子邮箱", "邮箱"), phone ("phone", "telephone", "mobile", "phone number", "电话", "手机号码").
- FillPlanner, blank matching, and the fill flow need no behavioral change; they operate on whatever fields a portfolio holds.

## 6. UI

- `FillModel` gains a `library` stage as the Fill mode home, `summaries: [PortfolioSummary]` published state, and intents: `refreshLibrary()`, `createPortfolio(kind:label:fromScratch:)`, `openForEdit(id:)`, `fillFrom(id:)` (loads the portfolio then proceeds to target selection), `addField(key:value:)` (marks dirty, userEdited true), `deletePortfolio(id:)`, `exportPortfolio(id:to:protection:)`, `importPortfolio(from:protection:)`, `saveToLibrary()` (create or save by whether an id is held; updates modifiedAt via caller-supplied timestamp). The extract flow lands in the SAME edit surface with the library as its save destination.
- `FillShell` home screen: portfolio list (label, kind badge, modified date, conflict and incomplete indicators), New Portfolio flow (kind + label sheet, then From documents / From scratch), per-row actions (Edit, Fill a document, Export, Delete with confirmation), Import button. The existing profile-builder surface becomes the create/edit screen: its Save button writes to the library without prompts; Export keeps the passphrase sheet; the Add Field control offers the kind's canonical keys (with display names) plus a custom-name text field.
- Save stays disabled while `conflictedKeys` is non-empty. Deleting the portfolio currently open for editing returns to the library home.
- The fill-review screen is unchanged.

## 7. CLI and MCP (read-only portal)

- CLI: `lda portfolio list` prints value-free summaries as JSON (the PortfolioSummary fields). `lda portfolio show <name-or-id>` prints one portfolio's summary plus its field KEYS (rawKey list) and conflicted keys; never values or snippets. `lda fill --portfolio <name-or-id>` is accepted as an alternative to `--profile <path>` (exactly one of the two; resolves by exact id, else unique label match; ambiguous or missing names produce a clear error listing candidates by label).
- MCP: `portfolio_list` and `portfolio_show` tools mirroring the CLI output; the `fill` tool gains an optional `portfolio` parameter, mutually exclusive with `profile`.
- Both edges construct the library at the same Application Support path; the Keychain entitles the same key access (CLI and MCP run unsandboxed in dev; the packaged sandboxed app uses its container's Application Support, which is the expected separation: the app's library is the app's; CLI in dev uses the user-level path. The library path is a single internal constant so a future shared-group container is one change).

## 8. Error handling

- Keychain unavailable or denied: portal shows an actionable error; nothing is written.
- Corrupt index: rebuilt from portfolio files (recovered labels); the user sees a one-time notice.
- Corrupt portfolio file: that entry shows as unreadable with a delete option; others unaffected.
- Import with wrong passphrase: the existing decryptionFailed error surfaces; nothing joins the library.
- Export to a path equal to a library file: refused (the library directory is managed; exports go elsewhere).
- Name collisions: labels are NOT unique keys (ids are); `fill --portfolio` by label fails with a candidate list when ambiguous.
- Deleting a portfolio that a fill review currently uses: the in-memory portfolio keeps working; the library entry is gone on next visit (documented; no referential lock in V1).

## 9. Testing

- PortfolioLibraryTests: CRUD round-trips; list decrypts only the index (no portfolio Keychain reads, asserted via a counting test double if cheap, else by file-access observation); atomic save (temp-then-rename; simulated failure between steps leaves the old file intact); orphan tolerance both directions; corrupt-index rebuild; index magic and service separation (an index file must not load as a portfolio and vice versa); export/import round-trip with passphrase and Keychain; a Keychain file whose key sits under the legacy extension-included account loads via the fallback (pins the migration promise); imported legacy JSON (no kind, no modifiedAt) defaults correctly.
- Domain tests: PortfolioKind decode default, modifiedAt decode default, canonical(for:) contents, conflict detection over the new keys.
- Prompt tests: profileSystem(for:) injects the right key lists per kind; the slot-validation warning fires when an edited body drops `{allowed_keys}`.
- FillPlanner tests: new synonym entries (English and Chinese) hit deterministically.
- FillModel tests: library stage transitions, create-from-scratch, addField, delete-returns-home, saveToLibrary create vs update, export/import seams.
- CLI and MCP tests: list/show value-free assertions (encode and scan for a planted value string), name-or-id resolution including the ambiguous-label error, `fill --portfolio` happy path, mutual exclusion with `--profile`.
- One live-model test: Individual-kind extraction from a synthetic identity letter (name, date of birth, passport number), grounded, then a fill into a fixture docx with `[Full Name]` and `[Passport Number]`.

## 10. Implementation phasing (preview for the plan)

1. Domain: rename to ClientPortfolio, PortfolioKind, new canonical keys, decode defaults, canonical(for:).
2. PortfolioLibrary with index container and resilience.
3. Prompt generalization (profileSystem(for:), slot validation) and synonym additions; extractProfile kind parameter.
4. FillModel library stage and intents; FillShell portal home, create/edit additions, Add Field.
5. CLI and MCP read-only portal plus `fill --portfolio`.
6. Live test, docs, final sweep, merge to `feat/lda-macos-core`.

Branch mechanics: implementation branches off `feat/lda-macos-core` in a `~/Developer/lda-worktrees` worktree per the project convention; this spec travels with the implementation branch.
