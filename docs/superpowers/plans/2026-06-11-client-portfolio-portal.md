# Client Portfolio Portal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A managed, encrypted portfolio library in the LDA macOS app: browse, create (from any documents or from scratch), edit (including adding fields), fill from, export, import, and delete client portfolios of three kinds (company, individual, general), with read-only CLI/MCP access.

**Architecture:** Builds directly on the merged fill-from-profile feature (`feat/lda-macos-core` at 3db2851). The domain type generalizes (ClientPortfolio + PortfolioKind + person-fact canonical keys), a new `PortfolioLibrary` unit owns an Application Support directory of per-portfolio `LDAPROF` containers plus one `LDAPIDX` encrypted index, the extraction prompt becomes kind-aware via an `{allowed_keys}` template slot, and the Fill mode UI gains a portal home stage. Spec: `docs/superpowers/specs/2026-06-11-client-portfolio-portal-design.md` (committed beside this plan).

**Tech Stack:** Swift 5.9 SPM, XCTest, CryptoKit AES-GCM via the existing `EncryptedContainer`, SwiftUI (Counsel), llama.cpp via `LLMEngine`.

---

## Read this first (context for a zero-context engineer)

- **Repo:** Swift package at `macos/LDACore`; implementation worktree created in Task 0 (NEVER build in the iCloud-synced primary checkout). House rules: English comments/strings; NO em-dash, NO en-dash-as-separator anywhere; standard file header comments (see any Sources file); purity (core never reads the clock; ISO-8601 timestamps come from edges); commit prefixes feat/fix/test/docs/refactor; `git -c commit.gpgsign=false commit` if 1Password signing errors.
- **The fill feature you are extending (all merged, all green at 510 tests):** `Domain/ProfileTypes.swift` (CompanyProfile, ProfileFieldKey with rawKey wire format and `.custom` fallback, Blank, FillPlan, FillReport), `Security/EncryptedContainer.swift` (shared AES-GCM container; RULE: each store KIND needs a distinct magic AND a distinct Keychain service; init takes magic/keychainService/containerDescription), `Security/ProfileStore.swift` (LDAPROF + service `ai.openclaw.lda.profilekey`), `Service/LDAFillService.swift` (extractProfile/planFill/applyFill + ExtractProfileResult), `Engine/PromptStore.swift` (defaultProfileSystem, profileUser, validate() calibrated for Chinese pass1/pass2 only), `Engine/FillPlanner.swift` (normalized synonym table, static normalizedTable cache), `Engine/ProfileExtractor.swift`, `LDAUI/FillModel.swift` (@MainActor, nonisolated(unsafe) static test seams, stage machine), `LDAUI/FillShell.swift` + `FillShellViews.swift` + `RootShell.swift`, `LDACLI/CLIFill.swift`, `LDAMCP/MCPFillTools.swift`.
- **Known latent bug this plan fixes (spec section 4):** FillShell derives per-file Keychain accounts as `url.lastPathComponent` (WITH extension, FillShell.swift around lines 534 and 620) while CLI/MCP use `deletingPathExtension().lastPathComponent`. Standard going forward: extension-less. Loads fall back to the legacy extension-included account.
- **Platform rules that have bitten before:** NSOpenPanel/NSSavePanel only, never `.fileImporter`; `@Environment(\.openSettings)` for Settings; FillModel seams are `nonisolated(unsafe) internal static var` reset in tearDown; Keychain tests use the tolerant `testKeychainRoundTripOrSkip` pattern (XCTSkip when the unsigned test process cannot use the Keychain); live-model tests gate on `LDA_MODEL_PATH` with XCTSkip.
- **TDD:** failing test first, watch it fail, implement, watch it pass, full suite, commit. Run from `~/Developer/lda-worktrees/portal/macos/LDACore` (Task 0 creates it): `swift test --filter <Class>`; full: `swift test 2>&1 | tail -3`. Baseline 510 green.
- **Before changing any existing file, read it fully.** Snippets here were written against the merged code but the executor reconciles.

## File structure

```
macos/LDACore/Sources/LDACore/
  Domain/ProfileTypes.swift              MODIFY  rename CompanyProfile->ClientPortfolio; PortfolioKind; kind+modifiedAt; new keys; canonical(for:)
  Security/ProfileStore.swift            MODIFY  standard/legacy account helpers (shared)
  Security/PortfolioLibrary.swift        CREATE  managed library (files + encrypted index + resilience)
  Service/LDAFillService.swift           MODIFY  extractProfile gains kind; assembles ClientPortfolio
  Engine/PromptStore.swift               MODIFY  profileSystem(for:) template + {allowed_keys} slot + validateProfileTemplate
  Engine/FillPlanner.swift               MODIFY  individual-key synonym entries
Sources/LDAUI/
  FillModel.swift                        MODIFY  library stage, summaries, portal intents, addField
  FillShell.swift / FillShellViews.swift MODIFY  portal home, New Portfolio flow, Add Field, export/import, account fix
Sources/LDACLI/CLIFill.swift             MODIFY  portfolio list/show; fill --portfolio
Sources/LDAMCP/MCPFillTools.swift        MODIFY  portfolio_list/portfolio_show; fill portfolio param
Sources/LDAMCP/MCPServer.swift           MODIFY  descriptors + dispatch
Tests/LDACoreTests/
  ProfileTypesTests.swift                MODIFY  kind/modifiedAt defaults, canonical(for:), new-key conflicts
  PortfolioLibraryTests.swift            CREATE
  ProfileStoreTests.swift                MODIFY  legacy-account fallback test
  PromptStoreTests.swift                 MODIFY  per-kind template, slot validation
  FillPlannerTests.swift                 MODIFY  person synonym hits
  FillModelTests.swift                   MODIFY  library stage + intents
  CLITests.swift / MCPTests.swift        MODIFY  portfolio commands/tools, value-free, name resolution
  FillLiveModelTests.swift               MODIFY  individual-kind live extraction + fill
```

---

### Task 0: Worktree, branch, baseline

- [ ] **Step 0.1:**
```bash
cd "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer"
git worktree add ~/Developer/lda-worktrees/portal -b feat/portfolio-portal feat/lda-macos-core
cd ~/Developer/lda-worktrees/portal
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/.claude/worktrees/sharp-mclean-ac18c5/docs/superpowers/specs/2026-06-11-client-portfolio-portal-design.md" docs/superpowers/specs/
cp "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/.claude/worktrees/sharp-mclean-ac18c5/docs/superpowers/plans/2026-06-11-client-portfolio-portal.md" docs/superpowers/plans/
git add docs && git -c commit.gpgsign=false commit -m "docs: import portfolio portal spec and plan"
```
- [ ] **Step 0.2:** `cd ~/Developer/lda-worktrees/portal/macos/LDACore && swift test 2>&1 | tail -3` Expected: 510 green. If red, STOP and surface.

All later tasks run from `~/Developer/lda-worktrees/portal/macos/LDACore`.

---

### Task 1: Domain generalization (rename, kind, modifiedAt, new keys, canonical(for:))

**Files:** Modify `Sources/LDACore/Domain/ProfileTypes.swift`; modify `Tests/LDACoreTests/ProfileTypesTests.swift`; mechanical rename across the repo.

- [ ] **Step 1.1: Write failing tests** (add to ProfileTypesTests):

```swift
func testPortfolioKindDecodeDefaultsToCompany() throws {
    // Legacy JSON written before kind existed.
    let legacy = """
    {"label":"Acme","fields":[],"sourceDocuments":[],"createdAtISO8601":"2026-06-10T00:00:00Z","incomplete":false}
    """.data(using: .utf8)!
    let portfolio = try JSONDecoder().decode(ClientPortfolio.self, from: legacy)
    XCTAssertEqual(portfolio.kind, .company)
    XCTAssertEqual(portfolio.modifiedAtISO8601, "2026-06-10T00:00:00Z")
}

func testKindAndModifiedAtRoundTrip() throws {
    var portfolio = ClientPortfolio(
        label: "Jane", fields: [], sourceDocuments: [],
        createdAtISO8601: "2026-06-11T00:00:00Z", incomplete: false
    )
    portfolio.kind = .individual
    portfolio.modifiedAtISO8601 = "2026-06-11T01:00:00Z"
    let back = try JSONDecoder().decode(ClientPortfolio.self, from: JSONEncoder().encode(portfolio))
    XCTAssertEqual(back.kind, .individual)
    XCTAssertEqual(back.modifiedAtISO8601, "2026-06-11T01:00:00Z")
}

func testCanonicalForKind() {
    let company = ProfileFieldKey.canonical(for: .company)
    XCTAssertTrue(company.contains(.companyName))
    XCTAssertTrue(company.contains(.email))
    XCTAssertTrue(company.contains(.phone))
    XCTAssertFalse(company.contains(.passportNumber))
    let individual = ProfileFieldKey.canonical(for: .individual)
    XCTAssertEqual(individual, [.clientName, .dateOfBirth, .nationality, .passportNumber,
                                .nationalIDNumber, .residentialAddress, .email, .phone])
    let general = ProfileFieldKey.canonical(for: .general)
    XCTAssertEqual(Set(general), Set(company).union(individual))
}

func testNewSingleValuedKeysConflict() {
    let a = ProfileField(key: .passportNumber, value: "E12345678", sourceDocument: "p.pdf",
                         sourceSnippet: "E12345678", snippetVerified: true, confidence: 0.9, userEdited: false)
    let b = ProfileField(key: .passportNumber, value: "E87654321", sourceDocument: "p2.pdf",
                         sourceSnippet: "E87654321", snippetVerified: true, confidence: 0.9, userEdited: false)
    let portfolio = ClientPortfolio(label: "x", fields: [a, b], sourceDocuments: [],
                                    createdAtISO8601: "2026-06-11T00:00:00Z", incomplete: false)
    XCTAssertEqual(portfolio.conflictedKeys, [.passportNumber])
}

func testNewKeysRawKeyRoundTrip() throws {
    let keys: [ProfileFieldKey] = [.clientName, .dateOfBirth, .nationality, .passportNumber,
                                   .nationalIDNumber, .residentialAddress, .email, .phone]
    let back = try JSONDecoder().decode([ProfileFieldKey].self, from: JSONEncoder().encode(keys))
    XCTAssertEqual(back, keys)
}
```

- [ ] **Step 1.2:** `swift test --filter ProfileTypesTests` Expected: compile FAILURE.
- [ ] **Step 1.3: Implement in ProfileTypes.swift:**
  1. Add `public enum PortfolioKind: String, Codable, Sendable, CaseIterable { case company, individual, general }` with a doc comment.
  2. Rename `CompanyProfile` to `ClientPortfolio` IN THIS FILE, add `public var kind: PortfolioKind` and `public var modifiedAtISO8601: String`. Keep the EXISTING memberwise init signature unchanged (kind defaults internally to `.company`, modifiedAt to createdAt) so call sites keep compiling; set both inside the init. Implement custom `init(from:)`/`encode(to:)` (or `decodeIfPresent` with defaults) so legacy JSON without the two keys decodes (kind `.company`, modifiedAt = decoded createdAt). NOTE: `Blank.candidateFieldIDs` already shows the manual-Codable-with-decodeIfPresent pattern in this file; mirror it.
  3. Add the eight canonical cases `clientName, dateOfBirth, nationality, passportNumber, nationalIDNumber, residentialAddress, email, phone` to `ProfileFieldKey`: extend the case list, `canonicalRaw` dictionary, the exhaustive `rawKey` switch (compiler enforces), `displayName`, and the ordered `canonical` array (append after the existing seventeen). They are all single-valued (NOT in `listLike`).
  4. Add `public static func canonical(for kind: PortfolioKind) -> [ProfileFieldKey]`: company = existing seventeen + email + phone; individual = the eight person keys in the order of the test; general = company list followed by the individual keys not already present (order: company then remaining person keys), with the test's Set equality as the contract.
- [ ] **Step 1.4: Mechanical rename across the repo:** `grep -rln "CompanyProfile" Sources Tests` then rename every occurrence to `ClientPortfolio` (types only; ProfileStore/extractProfile function NAMES keep "Profile", which still reads correctly). NO compatibility typealias. Build until clean: `swift build 2>&1 | tail -5`.
- [ ] **Step 1.5:** `swift test --filter ProfileTypesTests` PASS, then FULL suite green (every existing test compiles against the rename). Expected ~515.
- [ ] **Step 1.6:**
```bash
git add -A && git -c commit.gpgsign=false commit -m "feat: ClientPortfolio with kinds, modifiedAt, person canonical keys"
```

---

### Task 2: Keychain account reconciliation

**Files:** Modify `Sources/LDACore/Security/ProfileStore.swift`, `Sources/LDAUI/FillShell.swift`, `Sources/LDACLI/CLIFill.swift` + `CLI.swift` (if its helper applies), `Sources/LDAMCP/MCPFillTools.swift`; test in `Tests/LDACoreTests/ProfileStoreTests.swift`.

- [ ] **Step 2.1: Write failing tests** (ProfileStoreTests; use the tolerant Keychain skip pattern from MappingStoreTests):

```swift
func testStandardAccountDerivation() {
    let url = URL(fileURLWithPath: "/tmp/Acme Matter.ldaprofile")
    XCTAssertEqual(ProfileStore.standardAccount(for: url), "Acme Matter")
    XCTAssertEqual(ProfileStore.legacyAccount(for: url), "Acme Matter.ldaprofile")
}

func testKeychainLoadFallsBackToLegacyAccountOrSkip() throws {
    // Save under the LEGACY (extension-included) account directly, then load
    // via the standard helper, which must fall back. Skip when the unsigned
    // test process cannot use the Keychain (mirror testKeychainRoundTripOrSkip).
    ...save sampleProfile with .keychain(account: ProfileStore.legacyAccount(for: url))...
    ...let back = try ProfileStore.loadWithAccountFallback(from: url)...
    XCTAssertEqual(back.label, sample.label)
    ...delete both keychain keys in defer...
}
```

- [ ] **Step 2.2:** Run filter: compile FAILURE.
- [ ] **Step 2.3: Implement** in ProfileStore:
```swift
/// Standard per-file Keychain account: file name without extension.
public static func standardAccount(for url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
}
/// Legacy account written by the pre-portal UI: file name WITH extension.
public static func legacyAccount(for url: URL) -> String {
    url.lastPathComponent
}
/// Keychain-mode load that tries the standard account, then the legacy one.
public static func loadWithAccountFallback(from url: URL) throws -> ClientPortfolio {
    do { return try load(from: url, protection: .keychain(account: standardAccount(for: url))) }
    catch { return try load(from: url, protection: .keychain(account: legacyAccount(for: url))) }
}
```
Then update call sites: FillShell save AND load paths use `standardAccount` for saves and `loadWithAccountFallback` for Keychain loads (read FillShell.swift around the confirmSaveProfile/confirmLoadProfile sheets); CLI/MCP keychain loads route through `loadWithAccountFallback` (their saves already use the extension-less form; switch the derivation to call `standardAccount` so it is single-sourced). Keep passphrase paths untouched.
- [ ] **Step 2.4:** Filter PASS; full suite green.
- [ ] **Step 2.5:** `git add -A && git -c commit.gpgsign=false commit -m "fix: single Keychain account convention with legacy fallback"`

---

### Task 3: PortfolioLibrary

**Files:** Create `Sources/LDACore/Security/PortfolioLibrary.swift`; create `Tests/LDACoreTests/PortfolioLibraryTests.swift`.

Behavior (spec section 4): directory `<applicationSupport>/LDA/Portfolios/`; per-portfolio files `<uuid>.ldaprofile` in the existing LDAPROF container under the profile service with the single account `library`; index `index.ldapidx` in a NEW container (magic `LDAPIDX`, service `ai.openclaw.lda.libraryindexkey`, account `index`) holding `[PortfolioSummary]`; atomic temp-then-rename saves; list() decrypts only the index; orphan tolerance both ways (decryptable orphan rejoins with real label, undecryptable surfaces with placeholder "Recovered portfolio <short-id>"); corrupt index rebuilt from files; export/import re-encrypt; timestamps caller-supplied.

API (the test contract):

```swift
public struct PortfolioSummary: Equatable, Sendable, Codable {
    public var id: UUID
    public var label: String
    public var kind: PortfolioKind
    public var createdAtISO8601: String
    public var modifiedAtISO8601: String
    public var fieldCount: Int
    public var conflicted: Bool
}

public final class PortfolioLibrary {
    /// Injectable root for tests; production uses applicationSupport/LDA/Portfolios.
    public init(rootDirectory: URL? = nil) throws
    public func list() throws -> [PortfolioSummary]                  // sorted by label
    public func create(_ portfolio: ClientPortfolio) throws -> UUID
    public func load(id: UUID) throws -> ClientPortfolio
    public func save(_ portfolio: ClientPortfolio, id: UUID) throws  // atomic; updates index after file write
    public func delete(id: UUID) throws
    public func exportPortfolio(id: UUID, to url: URL, protection: MappingProtection) throws
    public func importPortfolio(from url: URL, protection: MappingProtection) throws -> UUID
    /// True when the most recent list() had to reconcile drift (rebuild or
    /// prune); the UI shows a one-time notice (spec section 8).
    public private(set) var lastListReconciled: Bool
}
```

Spec section 8 deltas folded in: `exportPortfolio` REFUSES a destination inside the library directory (throw; the library is managed); `lastListReconciled` is the channel for the corrupt-index one-time notice (Task 6 shows a banner when true after refresh).

- [ ] **Step 3.1: Write failing tests** (workDir-injected root per test). Keychain gating: every PortfolioLibrary test needs the Keychain (the container keys are Keychain-held), so gate the WHOLE class with a probe in `setUpWithError` that throws `XCTSkip` when the unsigned test process cannot use the Keychain. This is a NEW pattern; the existing precedent (MappingStoreTests' `skipIfKeychainUnavailable` used inside `testKeychainRoundTripOrSkip`) gates per-test; reuse its probe logic, lifted to setUp:
  - create/list/load/save/delete round trip; list sorted by label; summary fields correct (fieldCount, conflicted derived at save time).
  - save is atomic: no partial file visible after a simulated failure (write a portfolio, then save a corrupted-payload write through a test seam OR assert the temp-then-rename order by checking no `*.tmp` residue after success and that an interrupted-temp leftover is ignored by list()).
  - list decrypts only the index: construct 3 portfolios, then corrupt ONE portfolio file's bytes on disk; list() still returns 3 healthy-looking summaries (the corruption only surfaces on load) PROVING list does not open portfolio files.
  - orphan file (decryptable): write a portfolio file via the library then delete the index; list() rebuilds with the REAL label.
  - orphan file (undecryptable): drop a garbage `<uuid>.ldaprofile` into the directory; list() surfaces "Recovered portfolio <short-id>"-labeled entry; load(id:) for it throws; delete(id:) removes it.
  - index entry whose file is missing: removed from list().
  - cross-kind rejection: the index file must not load as a portfolio and vice versa (mirror testMappingContainerRejectedByProfileStore).
  - export with passphrase then re-import round trips; import of a legacy JSON profile (no kind/modifiedAt: build the file by saving a hand-built legacy-JSON payload through EncryptedContainer directly in the test) defaults kind to company.
  - exportPortfolio to a destination INSIDE the library directory throws (managed directory; spec section 8).
  - lastListReconciled: false after a clean list; true after a list that rebuilt a deleted index; false again on the following clean list.
- [ ] **Step 3.2:** Filter: compile FAILURE.
- [ ] **Step 3.3: Implement** PortfolioLibrary. Internals: `private let portfolioContainer = EncryptedContainer(magic: Array("LDAPROF".utf8), keychainService: "ai.openclaw.lda.profilekey", containerDescription: "Profile file")` used with account `library` (reuse ProfileStore's encode/decode helpers by making them internal if private, or replicate the 6-line encode/decode; prefer making ProfileStore's helpers internal and documenting); `private let indexContainer = EncryptedContainer(magic: Array("LDAPIDX".utf8), keychainService: "ai.openclaw.lda.libraryindexkey", containerDescription: "Portfolio index")` with account `index`. Atomic save: encode + seal to `<uuid>.ldaprofile.tmp` in the SAME directory, `FileManager.replaceItemAt`/rename, then rewrite the index. list(): read index, reconcile against directory contents per the resilience rules, prune/rebuild lazily (rewrite index only when drift was found). Summaries computed at create/save time from the portfolio (`conflicted = !portfolio.conflictedKeys.isEmpty`).
- [ ] **Step 3.4:** Filter PASS (10+ tests); full suite green.
- [ ] **Step 3.5:** `git add -A && git -c commit.gpgsign=false commit -m "feat: encrypted PortfolioLibrary with index and resilience"`

---

### Task 4: Kind-aware prompts and synonyms; extractProfile(kind:)

**Files:** Modify `Sources/LDACore/Engine/PromptStore.swift`, `Sources/LDACore/Engine/FillPlanner.swift`, `Sources/LDACore/Service/LDAFillService.swift`; tests in PromptStoreTests, FillPlannerTests, FillServiceTests.

- [ ] **Step 4.1: Failing tests:**
  - PromptStore: `profileSystem(for: .individual)` contains "passportNumber" and "dateOfBirth" and NOT "authorizedCapital"; `.company` contains "companyName" and "email" and NOT "passportNumber"; `.general` contains both; the editable template retains a literal `{allowed_keys}` slot and `validateProfileTemplate` returns a warning when an edited body drops the slot and [] when intact; the generalized opening covers identity documents (assert "identity" present).
  - FillPlanner: labels "Date of Birth", "出生日期", "Passport Number", "护照号码", "Full Name", "姓名", "Email Address", "电子邮箱" each match their keys deterministically against an individual portfolio.
  - FillService: extractProfile result carries the requested kind (seam-driven, no model).
- [ ] **Step 4.2:** Filter: FAILURE.
- [ ] **Step 4.3: Implement:**
  - PromptStore: rework `defaultProfileSystem` into `defaultProfileTemplate` containing `{allowed_keys}` where the key list sentence sits (keep EVERY existing rule sentence; generalize the opening to "legal, corporate, and identity documents (certificates, articles, registers, licenses, passports, utility statements, letters)"). RIPPLE THE COMPILER WILL NOT CATCH: `testProfilePromptDefaultsCarryJSONContractAndKeys` (PromptStoreTests around line 236) asserts four key names appear in `currentProfileSystem`; after templating, the body holds the `{allowed_keys}` slot, so RE-TARGET those assertions at the RENDERED `profileSystem(for: .company)` (and keep one assertion that the template itself carries the literal slot). `currentProfileTemplate` replaces `currentProfileSystem` (rename; update reset/PromptKind handling minimally; PromptKind case name stays `profile`). Add `public func profileSystem(for kind: PortfolioKind) -> String` that substitutes the slot with the rawKeys of `ProfileFieldKey.canonical(for: kind)` joined by ", ". Add `public static func validateProfileTemplate(_ body: String) -> [String]` (slot present; JSON contract sentence present), separate from `validate(_:)`. Update ProfileExtractor's call site to take the rendered system body (ProfileExtractor gains a `kind` or, cleaner, an init/extract parameter `systemPrompt: String`; choose: extract gains `kind: PortfolioKind` and asks the store; mirror how it currently reads currentProfileSystem and keep the TextCompleter seam unchanged).
  - FillPlanner synonym additions (normalize at construction as the table already does): clientName: "client name", "full name", "name of individual", "姓名"; dateOfBirth: "date of birth", "birth date", "dob", "出生日期"; nationality: "nationality", "citizenship", "国籍"; passportNumber: "passport number", "passport no", "护照号码", "护照号"; nationalIDNumber: "id number", "national id", "identity card number", "身份证号码", "身份证号"; residentialAddress: "residential address", "home address", "住址", "住宅地址"; email: "email", "e-mail", "email address", "电子邮箱", "邮箱"; phone: "phone", "telephone", "mobile", "phone number", "电话", "手机号码".
  - LDAFillService: `extractProfile(sources:label:kind:modelPath:createdAtISO8601:onProgress:)` (kind new, after label); assembles ClientPortfolio with kind and modifiedAt = createdAt. Update ALL callers: FillModel production call + extract seam signature (add kind; the four seam closures in FillModelTests around lines 30, 418, 440, 925 gain a parameter), FillShell's production extract call, CLIFill runExtractProfile (CLI gains `--kind company|individual|general` defaulting to company; validate the string), MCPFillTools callExtractProfile (optional `kind` param defaulting "company"), FillServiceTests, FillLiveModelTests.
- [ ] **Step 4.4:** Filters PASS; FULL suite green (the signature ripple is the risk; fix compile errors at every edge).
- [ ] **Step 4.5:** `git add -A && git -c commit.gpgsign=false commit -m "feat: kind-aware extraction prompt, person synonyms, extractProfile(kind:)"`

---

### Task 5: FillModel library stage and portal intents

**Files:** Modify `Sources/LDAUI/FillModel.swift`; tests in FillModelTests.

Contract: new first stage `case library` in FillStage (idle remains the pre-library boot state; the shell calls `refreshLibrary()` on appear which moves idle -> library). Published `summaries: [PortfolioSummary]`, `currentPortfolioID: UUID?`. Intents (sync where possible, async wrapping the library off-main like existing patterns; the library instance is injectable for tests: `nonisolated(unsafe) internal static var libraryForTesting: PortfolioLibrary?` plus a production lazy default):
- `refreshLibrary()` (loads summaries, stage = .library; failure -> failed with message)
- `createPortfolio(kind:label:fromScratch:createdAtISO8601:)`: fromScratch true -> empty ClientPortfolio held in memory, stage .profileReady, currentPortfolioID nil (assigned on first save); fromScratch false -> stage .profileReady with empty profile AND the source-adding extract flow as today (extraction then populates it; kind threads into the extract call)
- `openForEdit(id:)` (loads, stage .profileReady, currentPortfolioID set)
- `fillFrom(id:)` (loads, stage .profileReady AND immediately eligible for target open; keep simple: identical to openForEdit; the shell drives target opening)
- `addField(key: ProfileFieldKey, value: String)` (appends ProfileField with sourceDocument "manual entry", sourceSnippet "", snippetVerified false, confidence 1.0, userEdited true; marks dirty)
- `saveToLibrary(modifiedAtISO8601:)` (create when currentPortfolioID nil else save; clears dirty; refreshes summaries)
- `deletePortfolio(id:)` (refreshes; when it was the open one, back to .library)
- `exportPortfolio(id:to:protection:)`, `importPortfolio(from:protection:)` (refresh after)
- `backToLibrary()` (stage .library; clears in-flight blanks/picker like backToProfile does)
Field-name resolution for Add Field lives in the MODEL: `ProfileFieldKey(rawKey: typedName)` first (canonical when it matches), custom otherwise, per spec.

- [ ] **Step 5.1:** Failing tests: refreshLibrary publishes sorted summaries (fake library seam); createPortfolio fromScratch yields empty editable profile of the right kind; addField resolves "email" to canonical .email and "sealNumber" to custom; saveToLibrary create-then-update round trip (ids stable); deletePortfolio of the open portfolio returns stage .library; export/import call through the seam; failure paths -> .failed.
- [ ] **Step 5.2:** FAILURE. **Step 5.3:** Implement. COMPILE NOTE: adding `case library` to FillStage breaks FillShell.swift, which switches exhaustively over `model.stage` in TWO places with no default (around lines 88-91 and 119-122); add a minimal `.library` arm to both (render the profile-builder chrome or an EmptyView placeholder) so the package compiles; the real portal UI lands in Task 6. FillShellViews.swift's switch already has a default and is unaffected. **Step 5.4:** Filter + full green. 
- [ ] **Step 5.5:** `git add -A && git -c commit.gpgsign=false commit -m "feat: FillModel portfolio library stage and portal intents"`

---

### Task 6: Portal UI

**Files:** Modify `Sources/LDAUI/FillShell.swift`, `Sources/LDAUI/FillShellViews.swift`.

- Portal home (stage .library): list of summaries (label, kind badge, modified date, conflict and incomplete indicators), row actions Edit / Fill a document / Export / Delete (confirmation dialog), toolbar New Portfolio (sheet: kind picker + label field + From documents / From scratch) and Import (NSOpenPanel, `.ldaprofile`; protection: ask passphrase or Keychain mirroring the existing load sheet, loads via the Task 2 fallback for Keychain files).
- Create/edit surface: the existing profile-builder screen; Save now calls `saveToLibrary` (NO panel, NO passphrase); Export keeps the panel + optional passphrase (standard account when Keychain); Add Field control: a popover or sheet listing `ProfileFieldKey.canonical(for: kind)` display names plus a custom-name text field and value field, calling `model.addField`; the resolved key kind (canonical vs custom) is shown before confirming. Back button returns to the portal home (`backToLibrary`), warning on unsaved changes (profileDirty).
- Fill flow: Fill a document action = openForEdit then the existing Open Target affordance (already reachable from .profileReady after the earlier fix); no fill-review changes.
- Keep all platform rules (NSOpenPanel/NSSavePanel only; onReceive for pickerRequestID; .disabled isolation in RootShell untouched).

- [ ] **Step 6.1:** Implement portal home + wiring; `swift build` green.
- [ ] **Step 6.2:** Implement New Portfolio + Add Field + export/import sheets; build green; full suite green (UI logic stays in FillModel; no new UI test machinery).
- [ ] **Step 6.3:** Launch smoke: `swift run LDAApp` briefly; portal home renders; report.
- [ ] **Step 6.4:** `git add -A && git -c commit.gpgsign=false commit -m "feat: portfolio portal home, create/edit, add field, export/import UI"`

---

### Task 7: CLI read-only portal

**Files:** Modify `Sources/LDACLI/CLIFill.swift` (or sibling if near 800 lines); tests in CLITests.

- `lda portfolio list`: value-free JSON array of summaries. `lda portfolio show <name-or-id>`: one summary + field rawKeys + conflictedKeys; NEVER values/snippets. Resolution: exact UUID match first, else case-insensitive unique label; ambiguous -> error listing candidate labels; missing -> clear error.
- `lda fill --portfolio <name-or-id>` as alternative to `--profile` (exactly one; validate()); resolves via the library and proceeds identically (plan/apply semantics unchanged). `--passphrase` is irrelevant for library portfolios (Keychain only); reject the combination with a validation error. MECHANICAL NOTE: `Fill.profile` is currently a REQUIRED `@Option var profile: String`; demote it to `String?` and enforce the exactly-one rule in `validate()` (no ArgumentParser flag-group machinery needed).
- Injectable helpers + ParsableCommand `Portfolio` with subcommands `List`/`Show` added to LDARoot; library path shared via the PortfolioLibrary default init.

- [ ] **Step 7.1:** Failing tests: list value-free (plant a value, encode, scan absent); show by label and by id; ambiguous label error lists candidates; fill --portfolio happy path (plan mode) + mutual exclusion with --profile + passphrase rejection.
- [ ] **Step 7.2:** FAILURE. **Step 7.3:** Implement. **Step 7.4:** Filter + full green.
- [ ] **Step 7.5:** `git add -A && git -c commit.gpgsign=false commit -m "feat: lda portfolio list/show and fill --portfolio"`

---

### Task 8: MCP read-only portal

**Files:** Modify `Sources/LDAMCP/MCPFillTools.swift`, `Sources/LDAMCP/MCPServer.swift`; tests in MCPTests.

- Tools `portfolio_list` (no params) and `portfolio_show` (param `portfolio: string`, name-or-id), mirroring the CLI output dictionaries; `fill` tool gains optional `portfolio` param mutually exclusive with `profile` (exactly one required). Same `[String: Any]` precedent; descriptors + dispatch + describe arms for the new resolution errors.
- [ ] **Step 8.1:** Failing tests (tools/list advertises 7; list/show value-free; show by label; fill with portfolio param plan mode; both-params error; neither-param error). DELIBERATE EXISTING-TEST UPDATE: `MCPTests.swift` around line 479 pins `names.count == 5` ("expected exactly 5 tools"); update it to 7 as part of this task. This is the sanctioned exception to the never-weaken rule (a count assertion tracking the tool roster, not a behavioral weakening). **Step 8.2:** FAILURE. **Step 8.3:** Implement. **Step 8.4:** Filter + full green.
- [ ] **Step 8.5:** `git add -A && git -c commit.gpgsign=false commit -m "feat: portfolio_list, portfolio_show, fill portfolio param (MCP)"`

---

### Task 9: Live test, docs, sweep, merge

- [ ] **Step 9.1:** Extend `FillLiveModelTests` (same LDA_MODEL_PATH gate): individual-kind extraction from a synthetic identity letter (full name, date of birth, passport number in realistic phrasing); assert clientName or passportNumber extracted and grounded; fill a fixture docx containing "[Full Name]" and "[Passport Number]" end to end. Run with the local model if present (check ~/Developer/lda-models/lda-v2-Q4_K_M.gguf), report timing; otherwise verify skip.
- [ ] **Step 9.2:** Docs: `macos/LDACore/README.md` fill section gains a "Portfolio library" subsection (portal, kinds, library location, export/import, the two CLI commands, --kind flag, --portfolio flag); root README one sentence. No em-dashes.
- [ ] **Step 9.3:** `swift build 2>&1 | tail -2 && swift test 2>&1 | tail -3` all green; brief launch smoke.
- [ ] **Step 9.4:** Commit docs, then the two-move merge (feat/lda-macos-core is checked out at the PRIMARY iCloud checkout; merging there is fine, building is not):
```bash
cd ~/Developer/lda-worktrees/portal
git add -A && git -c commit.gpgsign=false commit -m "docs: portfolio portal docs and live model test"
git merge feat/lda-macos-core -m "merge: sync upstream feat/lda-macos-core" # expect already up to date unless upstream moved
cd macos/LDACore && swift test 2>&1 | tail -3
cd "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer"
git merge --ff-only feat/portfolio-portal
```
Expected: suite green in the worktree, clean fast-forward. If ff-only fails (upstream moved), repeat the sync step and retry.

---

## Execution notes

- Execute in order; Task 1's rename ripples everywhere, so it lands first and alone.
- Task 4's signature ripple (extractProfile kind) is the compile-risk task; budget reconciliation time at every edge.
- The final whole-feature review before the merge must WALK THE PORTAL WORKFLOW end to end in code (home -> create from scratch -> add field -> save -> edit -> fill -> export -> import -> delete), the lesson from the fill feature's unreachable-screen bug.
- Never weaken an existing test; if one breaks, the change is wrong (except the deliberate rename and signature updates, which adjust call sites, not assertions).
