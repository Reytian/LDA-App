# Fill from Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a reviewed, encrypted Company Profile from source documents (incorporation certificate, articles of association) fully on-device, then fill the blanks of DOCX drafts and AcroForm PDFs from that profile with per-blank review.

**Architecture:** Profile-first pipeline in the existing macOS Swift core (`macos/LDACore`): new deterministic units (`BlankDetector`, `DocxFiller`, `AcroFormFiller`, `ProfileStore`) plus two model-driven units (`ProfileExtractor`, `FillPlanner`) behind the existing `TextCompleter` seam, exposed through the `LDAService` facade to the Counsel UI, CLI, and MCP. Spec: `docs/superpowers/specs/2026-06-10-fill-from-profile-design.md` (committed beside this plan).

**Tech Stack:** Swift 5.9 SPM package, XCTest, PDFKit (AcroForm), ZIPFoundation (DOCX), CryptoKit + CommonCrypto (encrypted containers), llama.cpp via `LLMEngine` (on-device GGUF), SwiftUI (Counsel).

---

## Read this first (context for a zero-context engineer)

- **Repo layout:** the Swift package lives at `macos/LDACore` on branch `feat/lda-macos-core`. The repo's default checkout is under iCloud (`~/Documents/Vibe Code/Legal Document Anonymizer`); builds there get evicted and break. ALWAYS work in the worktree created in Task 0 under `~/Developer/`.
- **House rules (enforced in review):** all code comments and strings in English. No em-dash and no en-dash-as-separator anywhere, including docs and commit messages. Every new file carries the same header comment style as existing files (purpose paragraph plus the house-rules line).
- **Offset convention:** all span offsets are UTF-16 code units (NSRange-compatible). `ImportedDocument.text` from the importers aligns with `Span` offsets. Never index with `String.Index` math in engine code; use `NSString`.
- **Purity convention:** core units never read the clock or random sources beyond what exists; timestamps (`createdAtISO8601`) come from the caller at the edge.
- **TDD:** every task writes the failing test first, sees it fail, implements minimally, sees it pass, commits. Run tests from `macos/LDACore` with `swift test --filter <ClassName>`. The full suite (`swift test`) is currently green at 331 tests and must stay green.
- **Commit style:** `feat:`, `fix:`, `test:`, `docs:`, `refactor:` prefixes; no attribution trailers. If commit signing errors (1Password agent), use `git -c commit.gpgsign=false commit ...`.
- **Key existing APIs you will reuse (signatures verified):**
  - `TextCompleter`: `func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String` (in `Engine/LLMEngine.swift`; `LLMEngine` conforms).
  - `Chunker.chunk(_ text: String, targetChars: Int = 2000, overlapChars: Int = 350) -> [TextChunk]` where `TextChunk` has `text` and `startUTF16`.
  - `EntityLocator.spans(forValue:type:in:source:confidence:) -> [Span]` (case-insensitive occurrence finder).
  - `DocxRedactor.redact(original: URL, replacements: [Replacement], to: URL, nonBody: ... = nil)` writes arbitrary replacement strings into `w:t` runs, preserving formatting. `Replacement(span: Span, token: String)`; for filling, `token` carries the fill value.
  - `DocxImporter` / `PdfImporter` / `PdfOCRImporter` / `TextDocumentIO` produce `ImportedDocument` (`text`, `format`, `isScanned`, `pageCount`, `scannedPageIndexes`).
  - `MappingStore` (`Security/MappingStore.swift`): AES-GCM versioned container, magic `LDAMAP`, version 1, `MappingProtection.passphrase(String)` (PBKDF2-HMAC-SHA256, 200k iterations, 16-byte salt) or `.keychain(account:)` (service `ai.openclaw.lda.mappingkey`).
  - `LDAService` (enum of static funcs): `anonymize`, `restore`, `detect`, private `importDocument(...)` switching on file extension, private `makeDetector(modelPath:)`.
  - `PromptStore`: editable prompt bodies, `PromptKind` enum, `PromptSnapshot` (Codable), per-kind `current...` vars, `reset(_:)`, `validate(_:)`, user-prompt builders like `extractionUser(chunk:)`.
  - CLI pattern (`Sources/LDACLI/CLI.swift`): `ParsableCommand` structs whose `run()` calls injectable static helpers (`LDACLI.runAnonymize(...)`) and prints a Codable summary via `CLIJSON.encode(...)`. Errors wrap in `CLIRuntimeError`.
  - MCP pattern (`Sources/LDAMCP/MCPServer.swift`): `toolDescriptors` array plus a `switch` on tool name in `handleToolsCall`.
  - Test fixtures: `DocxIOTests` builds throwaway `.docx` files programmatically in `FileManager.temporaryDirectory` (`buildDocumentXML`, `writeFixtureDocx`); no binary fixtures are committed. Live-model tests are gated with `XCTSkip` unless `LDA_MODEL_PATH` is set.
- **Before changing any existing file, read it fully.** The snippets in this plan were verified against the branch but the executor must reconcile with current code.

## File structure (what gets created or modified)

```
macos/LDACore/Sources/LDACore/
  Domain/ProfileTypes.swift              CREATE  frozen domain types (profile, blanks, plan, report)
  Security/EncryptedContainer.swift      CREATE  shared AES-GCM container (factored out of MappingStore)
  Security/MappingStore.swift            MODIFY  delegate container plumbing to EncryptedContainer
  Security/ProfileStore.swift            CREATE  encrypted .ldaprofile persistence
  Engine/BlankDetector.swift             CREATE  deterministic blank detection in text
  Engine/ProfileJSONParser.swift         CREATE  defensive parser for profile extraction JSON
  Engine/ProfileExtractor.swift          CREATE  chunked, grounded, merged profile extraction
  Engine/FillPlanner.swift               CREATE  synonym table + batched model fallback matching
  Engine/PromptStore.swift               MODIFY  add profile + blankMatch prompt kinds
  IO/DocxFiller.swift                    CREATE  thin fill wrapper over DocxRedactor
  IO/AcroFormFiller.swift                CREATE  PDFKit text-widget enumeration and fill
  Service/LDAService.swift               MODIFY  extractProfile / planFill / applyFill facade ops
Sources/LDAUI/
  FillModel.swift                        CREATE  @MainActor view-model for both fill screens
  FillShell.swift                        CREATE  Fill mode UI (profile builder + fill review)
  AppShell.swift                         MODIFY  none of the review window internals; only referenced
  RootShell.swift                        CREATE  mode switcher hosting AppShell and FillShell
Sources/LDAApp/LDAApp.swift              MODIFY  show RootShell instead of AppShell
Sources/LDACLI/CLI.swift                 MODIFY  extract-profile and fill subcommands
Sources/LDAMCP/MCPServer.swift           MODIFY  extract_profile and fill tools
Tests/LDACoreTests/
  ProfileTypesTests.swift                CREATE
  EncryptedContainerTests.swift          CREATE  (plus MappingStore compatibility cases)
  ProfileStoreTests.swift                CREATE
  BlankDetectorTests.swift               CREATE
  DocxFillTests.swift                    CREATE
  AcroFormFillTests.swift                CREATE
  ProfileJSONParserTests.swift           CREATE
  ProfileExtractorTests.swift            CREATE
  FillPlannerTests.swift                 CREATE
  FillServiceTests.swift                 CREATE  facade-level tests
  FillModelTests.swift                   CREATE
  FillLiveModelTests.swift               CREATE  gated by LDA_MODEL_PATH
README.md (repo root)                    MODIFY  short feature section (final task)
```

Notes locked in by the spec: conflict state is derived, never stored; `FillReport` is value-free; `.ldaprofile` reuses the MappingStore container format with its own magic; underscore runs are two or more; bare `●`/`•` runs count as blanks; V1 fills AcroForm text widgets only.

---

### Task 0: Implementation worktree and baseline

**Files:** none changed in this task.

- [ ] **Step 0.1: Create the worktree off `feat/lda-macos-core` (outside iCloud)**

```bash
cd "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer"
mkdir -p ~/Developer/lda-worktrees
git worktree add ~/Developer/lda-worktrees/fill -b feat/fill-from-profile feat/lda-macos-core
```

Expected: new worktree at `~/Developer/lda-worktrees/fill` on branch `feat/fill-from-profile`.

- [ ] **Step 0.2: Copy the spec and this plan into the worktree and commit**

```bash
cd ~/Developer/lda-worktrees/fill
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/.claude/worktrees/sharp-mclean-ac18c5/docs/superpowers/specs/2026-06-10-fill-from-profile-design.md" docs/superpowers/specs/
cp "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/.claude/worktrees/sharp-mclean-ac18c5/docs/superpowers/plans/2026-06-10-fill-from-profile.md" docs/superpowers/plans/
git add docs && git -c commit.gpgsign=false commit -m "docs: import fill-from-profile spec and plan"
```

- [ ] **Step 0.3: Verify the baseline test suite is green**

```bash
cd ~/Developer/lda-worktrees/fill/macos/LDACore && swift test 2>&1 | tail -5
```

Expected: all tests pass (331 at time of writing). If the baseline is red, STOP and surface to the human.

All remaining tasks run from `~/Developer/lda-worktrees/fill/macos/LDACore` unless stated otherwise.

---

### Task 1: ProfileTypes domain file

**Files:**
- Create: `Sources/LDACore/Domain/ProfileTypes.swift`
- Test: `Tests/LDACoreTests/ProfileTypesTests.swift`

- [ ] **Step 1.1: Write the failing tests**

```swift
//
//  ProfileTypesTests.swift
//  LDACoreTests
//
//  Codable round-trips and derived-state logic for the fill-from-profile
//  domain types.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ProfileTypesTests: XCTestCase {

    private func field(
        key: ProfileFieldKey,
        value: String,
        verified: Bool = true,
        confidence: Double = 0.9
    ) -> ProfileField {
        ProfileField(
            key: key,
            value: value,
            sourceDocument: "cert.pdf",
            sourceSnippet: "snippet containing \(value)",
            snippetVerified: verified,
            confidence: confidence,
            userEdited: false
        )
    }

    func testProfileFieldKeyCanonicalRawValues() {
        XCTAssertEqual(ProfileFieldKey.companyName.rawKey, "companyName")
        XCTAssertEqual(ProfileFieldKey.custom("seal number").rawKey, "custom:seal number")
    }

    func testProfileFieldKeyCodableRoundTripCanonicalAndCustom() throws {
        let keys: [ProfileFieldKey] = [.companyName, .incorporationDate, .custom("seal number")]
        let data = try JSONEncoder().encode(keys)
        let back = try JSONDecoder().decode([ProfileFieldKey].self, from: data)
        XCTAssertEqual(back, keys)
    }

    func testUnknownRawKeyDecodesAsCustomNotError() throws {
        // Forward compatibility: a profile written by a newer build with a new
        // canonical key must still load; it degrades to custom.
        let data = Data("[\"futureKey\"]".utf8)
        let back = try JSONDecoder().decode([ProfileFieldKey].self, from: data)
        XCTAssertEqual(back, [.custom("futureKey")])
    }

    func testCompanyProfileCodableRoundTrip() throws {
        let profile = CompanyProfile(
            label: "Acme incorporation",
            fields: [field(key: .companyName, value: "Acme Holdings Limited")],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        let data = try JSONEncoder().encode(profile)
        let back = try JSONDecoder().decode(CompanyProfile.self, from: data)
        XCTAssertEqual(back, profile)
    }

    func testConflictedKeysDerivedForSingleValuedKeyOnly() {
        let profile = CompanyProfile(
            label: "x",
            fields: [
                field(key: .companyName, value: "Acme Holdings Limited"),
                field(key: .companyName, value: "Acme Holdings (HK) Limited"),
                field(key: .directorName, value: "Jane Roe"),
                field(key: .directorName, value: "John Doe")
            ],
            sourceDocuments: [],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        // companyName is single-valued: two distinct normalized values conflict.
        // directorName is list-like: many values are normal.
        XCTAssertEqual(profile.conflictedKeys, [.companyName])
    }

    func testConflictIgnoresCaseAndWhitespaceDuplicates() {
        let profile = CompanyProfile(
            label: "x",
            fields: [
                field(key: .companyName, value: "Acme  Holdings Limited"),
                field(key: .companyName, value: "acme holdings limited")
            ],
            sourceDocuments: [],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        XCTAssertEqual(profile.conflictedKeys, [])
    }

    func testBlankAndFillReportCodableRoundTrip() throws {
        let blank = Blank(
            location: .textSpan(start: 10, end: 14),
            label: "Company Name",
            context: "between [Company Name], a company",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .unmatched
        )
        let data = try JSONEncoder().encode(blank)
        let back = try JSONDecoder().decode(Blank.self, from: data)
        XCTAssertEqual(back, blank)

        let report = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/out.docx"),
            filledCount: 3,
            skipped: [SkippedBlank(label: "Fax", locationDescription: "field Fax", reason: "no matching field")]
        )
        let rdata = try JSONEncoder().encode(report)
        let rback = try JSONDecoder().decode(FillReport.self, from: rdata)
        XCTAssertEqual(rback, report)
    }
}
```

- [ ] **Step 1.2: Run to verify failure**

Run: `swift test --filter ProfileTypesTests 2>&1 | tail -5`
Expected: compile FAILURE (types do not exist yet).

- [ ] **Step 1.3: Implement `ProfileTypes.swift`**

```swift
//
//  ProfileTypes.swift
//  LDACore
//
//  Frozen public domain types for the fill-from-profile feature: the extracted
//  Company Profile, detected blanks in a fill target, the fill plan, and the
//  value-free fill report.
//
//  Offset convention: BlankLocation.textSpan offsets are UTF-16 code units into
//  ImportedDocument.text, NSRange-compatible, matching Span in CoreTypes.swift.
//
//  Conflict state is DERIVED, never stored: a single-valued key holding more
//  than one distinct normalized value is in conflict (see conflictedKeys).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ProfileFieldKey

/// The canonical fact kinds a Company Profile can hold, plus a custom escape
/// hatch for anything else the model finds worth keeping. Codable as a plain
/// string; unknown canonical strings decode as .custom for forward
/// compatibility.
public enum ProfileFieldKey: Hashable, Sendable {
    case companyName
    case companyNameLocal
    case formerName
    case entityKind
    case jurisdiction
    case companyNumber
    case incorporationDate
    case registeredOffice
    case authorizedCapital
    case issuedCapital
    case parValue
    case shareClass
    case directorName
    case shareholderName
    case shareholderShares
    case companySecretary
    case registeredAgent
    case custom(String)

    /// The canonical cases in stable order, excluding custom.
    public static let canonical: [ProfileFieldKey] = [
        .companyName, .companyNameLocal, .formerName, .entityKind,
        .jurisdiction, .companyNumber, .incorporationDate, .registeredOffice,
        .authorizedCapital, .issuedCapital, .parValue, .shareClass,
        .directorName, .shareholderName, .shareholderShares,
        .companySecretary, .registeredAgent
    ]

    /// Keys that may legitimately hold several distinct values.
    public static let listLike: Set<ProfileFieldKey> = [
        .formerName, .shareClass, .directorName, .shareholderName,
        .shareholderShares
    ]

    private static let canonicalRaw: [String: ProfileFieldKey] = [
        "companyName": .companyName,
        "companyNameLocal": .companyNameLocal,
        "formerName": .formerName,
        "entityKind": .entityKind,
        "jurisdiction": .jurisdiction,
        "companyNumber": .companyNumber,
        "incorporationDate": .incorporationDate,
        "registeredOffice": .registeredOffice,
        "authorizedCapital": .authorizedCapital,
        "issuedCapital": .issuedCapital,
        "parValue": .parValue,
        "shareClass": .shareClass,
        "directorName": .directorName,
        "shareholderName": .shareholderName,
        "shareholderShares": .shareholderShares,
        "companySecretary": .companySecretary,
        "registeredAgent": .registeredAgent
    ]

    /// The stable wire string. Canonical keys use their name; custom keys are
    /// prefixed so they can never collide with a future canonical key.
    public var rawKey: String {
        switch self {
        case .custom(let name): return "custom:\(name)"
        default:
            // Safe: every non-custom case is in canonicalRaw by construction.
            return ProfileFieldKey.canonicalRaw.first { $0.value == self }!.key
        }
    }

    /// Resolve a wire string. Unknown strings become .custom(raw) so profiles
    /// written by newer builds still load.
    public init(rawKey: String) {
        if rawKey.hasPrefix("custom:") {
            self = .custom(String(rawKey.dropFirst("custom:".count)))
        } else if let canonical = ProfileFieldKey.canonicalRaw[rawKey] {
            self = canonical
        } else {
            self = .custom(rawKey)
        }
    }

    /// A short human label for UI and CLI output.
    public var displayName: String {
        switch self {
        case .companyName: return "Company name"
        case .companyNameLocal: return "Company name (local language)"
        case .formerName: return "Former name"
        case .entityKind: return "Entity kind"
        case .jurisdiction: return "Jurisdiction"
        case .companyNumber: return "Company number"
        case .incorporationDate: return "Incorporation date"
        case .registeredOffice: return "Registered office"
        case .authorizedCapital: return "Authorized capital"
        case .issuedCapital: return "Issued capital"
        case .parValue: return "Par value"
        case .shareClass: return "Share class"
        case .directorName: return "Director"
        case .shareholderName: return "Shareholder"
        case .shareholderShares: return "Shareholder shares"
        case .companySecretary: return "Company secretary"
        case .registeredAgent: return "Registered agent"
        case .custom(let name): return name
        }
    }
}

extension ProfileFieldKey: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawKey: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawKey)
    }
}

// MARK: - ProfileField

/// One extracted fact with provenance. sourceSnippet is the verbatim line or
/// sentence the value came from; snippetVerified is true only when that
/// snippet was located verbatim (case-insensitive) in the imported source
/// text.
public struct ProfileField: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var key: ProfileFieldKey
    public var value: String
    public var sourceDocument: String
    public var sourceSnippet: String
    public var snippetVerified: Bool
    public var confidence: Double
    public var userEdited: Bool

    public init(
        id: UUID = UUID(),
        key: ProfileFieldKey,
        value: String,
        sourceDocument: String,
        sourceSnippet: String,
        snippetVerified: Bool,
        confidence: Double,
        userEdited: Bool
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.sourceDocument = sourceDocument
        self.sourceSnippet = sourceSnippet
        self.snippetVerified = snippetVerified
        self.confidence = confidence
        self.userEdited = userEdited
    }

    /// Normalization used for dedupe and conflict detection: case folded,
    /// whitespace collapsed.
    public var normalizedValue: String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - CompanyProfile

/// The reviewed, persistable profile. createdAtISO8601 is supplied by the
/// caller per the purity rule. incomplete mirrors the LJE-001 posture: true
/// when any extraction segment was truncated, so fields may be missing.
public struct CompanyProfile: Equatable, Sendable, Codable {
    public var label: String
    public var fields: [ProfileField]
    public var sourceDocuments: [String]
    public var createdAtISO8601: String
    public var incomplete: Bool

    public init(
        label: String,
        fields: [ProfileField],
        sourceDocuments: [String],
        createdAtISO8601: String,
        incomplete: Bool
    ) {
        self.label = label
        self.fields = fields
        self.sourceDocuments = sourceDocuments
        self.createdAtISO8601 = createdAtISO8601
        self.incomplete = incomplete
    }

    /// Single-valued keys currently holding more than one distinct normalized
    /// value. Derived at call time; nothing is stored.
    public var conflictedKeys: [ProfileFieldKey] {
        var valuesByKey: [ProfileFieldKey: Set<String>] = [:]
        for field in fields where !ProfileFieldKey.listLike.contains(field.key) {
            if case .custom = field.key { continue }
            valuesByKey[field.key, default: []].insert(field.normalizedValue)
        }
        return ProfileFieldKey.canonical.filter { (valuesByKey[$0]?.count ?? 0) > 1 }
    }
}

// MARK: - Blank

/// Where a blank lives in the fill target.
public enum BlankLocation: Equatable, Sendable, Codable {
    /// UTF-16 offsets into the imported target text (NSRange semantics).
    case textSpan(start: Int, end: Int)
    /// The AcroForm field name of a text widget.
    case acroFormField(name: String)
}

/// Review status of one blank.
public enum BlankStatus: String, Equatable, Sendable, Codable {
    case proposed
    case confirmed
    case rejected
    case unmatched
}

/// One detected blank, its label and context, and the proposed fill.
public struct Blank: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var location: BlankLocation
    /// The bracket contents, handlebars name, or AcroForm field name. Empty
    /// for bare underscore and dot placeholders.
    public var label: String
    /// Text window around the blank, for matching and for the review UI.
    public var context: String
    /// The ProfileField.id this blank is proposed to take its value from.
    public var proposedFieldID: UUID?
    /// The value that would be written. Defaults to the field's canonical
    /// value; the planner may propose a format adaptation, which review shows
    /// beside the verbatim profile value.
    public var proposedValue: String?
    public var status: BlankStatus

    public init(
        id: UUID = UUID(),
        location: BlankLocation,
        label: String,
        context: String,
        proposedFieldID: UUID?,
        proposedValue: String?,
        status: BlankStatus
    ) {
        self.id = id
        self.location = location
        self.label = label
        self.context = context
        self.proposedFieldID = proposedFieldID
        self.proposedValue = proposedValue
        self.status = status
    }
}

// MARK: - FillPlan

/// The reviewable plan for one target document.
public struct FillPlan: Equatable, Sendable, Codable {
    public var targetFormat: DocumentFormat
    public var blanks: [Blank]
    /// AcroForm widgets V1 will not auto-fill (checkbox, radio, choice),
    /// surfaced so the report can list them as manual items.
    public var manualWidgetNames: [String]

    public init(targetFormat: DocumentFormat, blanks: [Blank], manualWidgetNames: [String] = []) {
        self.targetFormat = targetFormat
        self.blanks = blanks
        self.manualWidgetNames = manualWidgetNames
    }
}

// MARK: - FillReport

/// A skipped blank, described without its value.
public struct SkippedBlank: Equatable, Sendable, Codable {
    public var label: String
    public var locationDescription: String
    public var reason: String

    public init(label: String, locationDescription: String, reason: String) {
        self.label = label
        self.locationDescription = locationDescription
        self.reason = reason
    }
}

/// The value-free outcome of an apply run. Deliberately contains no filled
/// values so the report sidecar leaks no PII.
public struct FillReport: Equatable, Sendable, Codable {
    public var outputURL: URL
    public var filledCount: Int
    public var skipped: [SkippedBlank]

    public init(outputURL: URL, filledCount: Int, skipped: [SkippedBlank]) {
        self.outputURL = outputURL
        self.filledCount = filledCount
        self.skipped = skipped
    }
}
```

- [ ] **Step 1.4: Run to verify pass**

Run: `swift test --filter ProfileTypesTests 2>&1 | tail -5`
Expected: PASS (all ProfileTypesTests).

- [ ] **Step 1.5: Commit**

```bash
git add Sources/LDACore/Domain/ProfileTypes.swift Tests/LDACoreTests/ProfileTypesTests.swift
git -c commit.gpgsign=false commit -m "feat: add fill-from-profile domain types"
```

---

### Task 2: EncryptedContainer refactor (shared by MappingStore and ProfileStore)

**Files:**
- Create: `Sources/LDACore/Security/EncryptedContainer.swift`
- Modify: `Sources/LDACore/Security/MappingStore.swift`
- Test: `Tests/LDACoreTests/EncryptedContainerTests.swift`

**Goal:** factor the container format (magic, version, protection tag, salt, AES-GCM seal/open, PBKDF2, Keychain key handling) out of `MappingStore` into one shared unit parameterized by magic bytes and Keychain service string. `MappingStore`'s public API, on-disk format (magic `LDAMAP`, version 1), and Keychain service (`ai.openclaw.lda.mappingkey`) MUST NOT change.

- [ ] **Step 2.1: Write the failing tests**

```swift
//
//  EncryptedContainerTests.swift
//  LDACoreTests
//
//  The shared encrypted container: round trips, tamper detection, wrong
//  passphrase, and MappingStore on-disk compatibility across the refactor.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EncryptedContainerTests: XCTestCase {

    private let container = EncryptedContainer(
        magic: Array("LDATEST".utf8),
        keychainService: "ai.openclaw.lda.testkey",
        containerDescription: "Test container"
    )

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    func testPassphraseRoundTrip() throws {
        let url = tempURL("bin")
        let payload = Data("secret payload".utf8)
        try container.save(payload, to: url, protection: .passphrase("hunter2 long enough"))
        let back = try container.load(from: url, protection: .passphrase("hunter2 long enough"))
        XCTAssertEqual(back, payload)
    }

    func testWrongPassphraseFails() throws {
        let url = tempURL("bin")
        try container.save(Data("x".utf8), to: url, protection: .passphrase("right one"))
        XCTAssertThrowsError(try container.load(from: url, protection: .passphrase("wrong one")))
    }

    func testTamperedContainerFails() throws {
        let url = tempURL("bin")
        try container.save(Data("payload".utf8), to: url, protection: .passphrase("p p p p"))
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: url)
        XCTAssertThrowsError(try container.load(from: url, protection: .passphrase("p p p p")))
    }

    func testWrongMagicRejected() throws {
        let url = tempURL("bin")
        try container.save(Data("payload".utf8), to: url, protection: .passphrase("p p p p"))
        let other = EncryptedContainer(
            magic: Array("LDAOTHER".utf8),
            keychainService: "ai.openclaw.lda.testkey",
            containerDescription: "Other container"
        )
        XCTAssertThrowsError(try other.load(from: url, protection: .passphrase("p p p p")))
    }

    /// The refactor must not change MappingStore's on-disk format. A container
    /// saved with MappingStore BEFORE this refactor (fixture bytes inlined
    /// below, generated at Step 2.2) must still load AFTER.
    func testMappingStorePreRefactorFixtureStillLoads() throws {
        // FIXTURE_PLACEHOLDER: Step 2.2 generates these bytes on the
        // pre-refactor build and inlines them as a base64 literal.
        let base64 = "REPLACED_IN_STEP_2_2"
        let url = tempURL("ldamap")
        try Data(base64Encoded: base64)!.write(to: url)
        let mapping = try MappingStore.load(from: url, protection: .passphrase("fixture pass"))
        XCTAssertEqual(mapping.entries["{PERSON_1}"]?.value, "Jane Roe")
    }
}
```

- [ ] **Step 2.2: Generate the compatibility fixture on the PRE-refactor build**

Write a tiny throwaway test (or a `swift run` snippet) on the current code that saves a one-entry `Mapping` (`{PERSON_1}` -> "Jane Roe") via `MappingStore.save(..., protection: .passphrase("fixture pass"))`, prints the file's base64, and paste that literal into `testMappingStorePreRefactorFixtureStillLoads`. Delete the throwaway. Read `MappingStore.swift` fully first; mirror its actual save signature.

- [ ] **Step 2.3: Run to verify failure**

Run: `swift test --filter EncryptedContainerTests 2>&1 | tail -5`
Expected: compile FAILURE (`EncryptedContainer` does not exist).

- [ ] **Step 2.4: Implement the refactor**

Create `EncryptedContainer.swift` by MOVING the private helpers from `MappingStore.swift` (`seal`, `open`, `deriveKey`, `makeContainer`, `parseContainer`, `ParsedContainer`, `ProtectionTag`, `randomBytes`, and the Keychain helpers `fetchOrCreateKeychainKey`, `fetchKeychainKey`, `lookupKeychainKey`, `addKeychainKey`) into a `public struct EncryptedContainer` with stored `magic: [UInt8]` and `keychainService: String`, exposing:

```swift
public struct EncryptedContainer {
    public let magic: [UInt8]
    public let keychainService: String
    /// Noun used in error messages ("Mapping sidecar", "Profile file").
    /// REQUIRED, no default, so a new store can never silently inherit the
    /// mapping wording.
    public let containerDescription: String
    public static let containerVersion: UInt8 = 1

    public init(magic: [UInt8], keychainService: String, containerDescription: String) { ... }

    /// Encrypt plaintext and write the versioned container.
    public func save(_ plaintext: Data, to url: URL, protection: MappingProtection) throws

    /// Read, authenticate, and decrypt a container written by save.
    public func load(from url: URL, protection: MappingProtection) throws -> Data

    /// Delete the Keychain key for an account under this container's service.
    public func deleteKeychainKey(account: String) throws
}
```

Rules for the move:
- Bodies move verbatim except that the magic constant, version constant, and `keychainService` string become reads of the struct's stored properties.
- The moved `parseContainer` embeds "Mapping sidecar" in six error strings (MappingStore.swift lines 353 through 384); those become interpolations of the REQUIRED `containerDescription` property (MappingStore passes "Mapping sidecar", ProfileStore passes "Profile file") so ProfileStore failures never report themselves as mapping errors. Do not give the init parameter a default.
- Error cases keep using the existing `DocumentIOError` cases (`decryptionFailed`, `keychainError(status:)`, corrupt-container case as currently named). Do not invent new error types.
- `MappingProtection` stays where it is, unchanged, and is reused as the shared protection type (renaming it is cosmetic churn; skip it).
- `MappingStore.save`/`load`/`deleteKeychainKey` become thin delegates over a `private static let container = EncryptedContainer(magic: Array("LDAMAP".utf8), keychainService: "ai.openclaw.lda.mappingkey", containerDescription: "Mapping sidecar")` plus its existing JSON encode/decode of `Mapping`.

- [ ] **Step 2.5: Run the new tests and the old suites**

Run: `swift test --filter EncryptedContainerTests 2>&1 | tail -5` then `swift test --filter MappingStoreTests 2>&1 | tail -5` then `swift test --filter EncryptedStoreTests 2>&1 | tail -5`
Expected: PASS, PASS, PASS (pre-existing mapping tests prove the delegation kept behavior).

- [ ] **Step 2.6: Commit**

```bash
git add Sources/LDACore/Security/EncryptedContainer.swift Sources/LDACore/Security/MappingStore.swift Tests/LDACoreTests/EncryptedContainerTests.swift
git -c commit.gpgsign=false commit -m "refactor: extract shared EncryptedContainer from MappingStore"
```

---

### Task 3: ProfileStore (.ldaprofile persistence)

**Files:**
- Create: `Sources/LDACore/Security/ProfileStore.swift`
- Test: `Tests/LDACoreTests/ProfileStoreTests.swift`

- [ ] **Step 3.1: Write the failing tests**

```swift
//
//  ProfileStoreTests.swift
//  LDACoreTests
//
//  Encrypted .ldaprofile round trips and failure modes.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ProfileStoreTests: XCTestCase {

    private func sampleProfile() -> CompanyProfile {
        CompanyProfile(
            label: "Acme",
            fields: [
                ProfileField(
                    key: .companyName,
                    value: "Acme Holdings Limited",
                    sourceDocument: "cert.pdf",
                    sourceSnippet: "the name of the company is Acme Holdings Limited",
                    snippetVerified: true,
                    confidence: 0.95,
                    userEdited: false
                )
            ],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ldaprofile")
    }

    func testPassphraseRoundTrip() throws {
        let url = tempURL()
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase("long enough pass"))
        let back = try ProfileStore.load(from: url, protection: .passphrase("long enough pass"))
        XCTAssertEqual(back, sampleProfile())
    }

    func testWrongPassphraseFails() throws {
        let url = tempURL()
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase("right right right"))
        XCTAssertThrowsError(try ProfileStore.load(from: url, protection: .passphrase("wrong wrong wrong")))
    }

    func testPlaintextNeverOnDisk() throws {
        let url = tempURL()
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase("long enough pass"))
        let raw = try Data(contentsOf: url)
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "Acme Holdings"))
        XCTAssertFalse(raw.range(of: Data("Acme Holdings".utf8)) != nil)
    }

    func testMappingContainerRejectedByProfileStore() throws {
        // A .ldamap container must not load as a profile (different magic).
        let mapping = Mapping(entries: [:], createdAtISO8601: "2026-06-10T00:00:00Z")
        let url = tempURL()
        try MappingStore.save(mapping, to: url, protection: .passphrase("p p p p p"))
        XCTAssertThrowsError(try ProfileStore.load(from: url, protection: .passphrase("p p p p p")))
    }
}
```

Note: read `CoreTypes.swift` for the real `Mapping` initializer and adjust `testMappingContainerRejectedByProfileStore` to compile against it.

- [ ] **Step 3.2: Run to verify failure**

Run: `swift test --filter ProfileStoreTests 2>&1 | tail -5`
Expected: compile FAILURE (`ProfileStore` does not exist).

- [ ] **Step 3.3: Implement `ProfileStore.swift`**

```swift
//
//  ProfileStore.swift
//  LDACore
//
//  Encrypted persistence for CompanyProfile (.ldaprofile). The profile is real
//  PII and never touches disk in plaintext. Same container format and
//  protection modes as MappingStore, with its own magic and Keychain service.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum ProfileStore {

    /// The default file extension for saved profiles.
    public static let fileExtension = "ldaprofile"

    private static let container = EncryptedContainer(
        magic: Array("LDAPROF".utf8),
        keychainService: "ai.openclaw.lda.profilekey",
        containerDescription: "Profile file"
    )

    public static func save(
        _ profile: CompanyProfile,
        to url: URL,
        protection: MappingProtection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(profile)
        try container.save(plaintext, to: url, protection: protection)
    }

    public static func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> CompanyProfile {
        let plaintext = try container.load(from: url, protection: protection)
        return try JSONDecoder().decode(CompanyProfile.self, from: plaintext)
    }

    public static func deleteKeychainKey(account: String) throws {
        try container.deleteKeychainKey(account: account)
    }
}
```

- [ ] **Step 3.4: Run to verify pass**

Run: `swift test --filter ProfileStoreTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 3.5: Commit**

```bash
git add Sources/LDACore/Security/ProfileStore.swift Tests/LDACoreTests/ProfileStoreTests.swift
git -c commit.gpgsign=false commit -m "feat: encrypted ProfileStore for .ldaprofile"
```

---

### Task 4: BlankDetector (deterministic)

**Files:**
- Create: `Sources/LDACore/Engine/BlankDetector.swift`
- Test: `Tests/LDACoreTests/BlankDetectorTests.swift`

Spec rules: bracketed labels (contents up to roughly 60 chars, single line), underscore runs of two or more, bare `●`/`•` runs outside brackets, handlebars `{{name}}`, guillemets `«Name»`. Labels that are only underscores, dots, or whitespace normalize to the empty label. Overlapping matches resolve by pattern priority (bracketed and handlebars and guillemets over bare runs), then by position.

- [ ] **Step 4.1: Write the failing tests**

```swift
//
//  BlankDetectorTests.swift
//  LDACoreTests
//
//  Deterministic blank detection: every supported convention, label
//  normalization, context windows, overlap resolution, and offsets.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class BlankDetectorTests: XCTestCase {

    private func labels(_ text: String) -> [String] {
        BlankDetector.detect(in: text).map(\.label)
    }

    func testBracketedLabel() {
        let text = "between [Company Name], a company incorporated in [Jurisdiction]"
        let blanks = BlankDetector.detect(in: text)
        XCTAssertEqual(blanks.map(\.label), ["Company Name", "Jurisdiction"])
        guard case .textSpan(let start, let end) = blanks[0].location else {
            return XCTFail("expected textSpan")
        }
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: start, length: end - start)), "[Company Name]")
    }

    func testBracketedDotAndUnderscoreContentsNormalizeToEmptyLabel() {
        XCTAssertEqual(labels("on [●] and [•] and [___]"), ["", "", ""])
    }

    func testUnderscoreRunsTwoOrMore() {
        let blanks = BlankDetector.detect(in: "this ___ day of ____, 20__")
        XCTAssertEqual(blanks.count, 3)
        XCTAssertEqual(blanks.map(\.label), ["", "", ""])
    }

    func testSingleUnderscoreIgnored() {
        XCTAssertEqual(BlankDetector.detect(in: "a_b and snake_case").count, 0)
    }

    func testBareDotPlaceholders() {
        XCTAssertEqual(BlankDetector.detect(in: "the sum of ●● dollars and • cents").count, 2)
    }

    func testHandlebarsAndGuillemets() {
        XCTAssertEqual(labels("{{company_name}} and «IncorporationDate»"), ["company_name", "IncorporationDate"])
    }

    func testHandlebarsUnderscoreDoesNotDoubleReport() {
        // The underscores inside {{company_name}} must not surface as a second
        // underscore-run blank.
        XCTAssertEqual(BlankDetector.detect(in: "{{company_name}}").count, 1)
    }

    func testBracketContentsLongerThanSixtyCharsIgnored() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(BlankDetector.detect(in: "see [\(long)] there").count, 0)
    }

    func testBracketAcrossNewlineIgnored() {
        XCTAssertEqual(BlankDetector.detect(in: "see [Section\n4.2] there").count, 0)
    }

    func testContextWindowSurroundsBlank() {
        let prefix = String(repeating: "a", count: 300)
        let suffix = String(repeating: "b", count: 300)
        let blanks = BlankDetector.detect(in: prefix + " [Company Name] " + suffix)
        XCTAssertEqual(blanks.count, 1)
        XCTAssertTrue(blanks[0].context.contains("[Company Name]"))
        XCTAssertLessThanOrEqual((blanks[0].context as NSString).length, 240 + ("[Company Name]" as NSString).length + 2)
    }

    func testCJKContextOffsetsAreUTF16Safe() {
        let text = "本公司（下称「公司」）于 [成立日期] 注册成立。emoji 😀 tail [Company Name] end"
        let blanks = BlankDetector.detect(in: text)
        XCTAssertEqual(blanks.map(\.label), ["成立日期", "Company Name"])
        for blank in blanks {
            guard case .textSpan(let start, let end) = blank.location else { return XCTFail() }
            let surface = (text as NSString).substring(with: NSRange(location: start, length: end - start))
            XCTAssertTrue(surface.hasPrefix("[") && surface.hasSuffix("]"))
        }
    }

    func testBlanksSortedByPosition() {
        let blanks = BlankDetector.detect(in: "[B] then ___ then {{c}}")
        let starts: [Int] = blanks.compactMap {
            if case .textSpan(let start, _) = $0.location { return start } else { return nil }
        }
        XCTAssertEqual(starts, starts.sorted())
    }
}
```

- [ ] **Step 4.2: Run to verify failure**

Run: `swift test --filter BlankDetectorTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 4.3: Implement `BlankDetector.swift`**

```swift
//
//  BlankDetector.swift
//  LDACore
//
//  Deterministic detection of fill blanks in imported target text. No model
//  involvement. Supported conventions: bracketed labels [Company Name] and
//  [●] [•] [TBD] [___], underscore runs of two or more, bare ● or • runs,
//  handlebars {{field}}, and merge-field guillemets «Field».
//
//  Offsets are UTF-16 code units (NSRange semantics) into the supplied text,
//  matching the convention in CoreTypes.swift, so DocxFiller can hand them to
//  DocxRedactor unchanged.
//
//  False positives (cross-reference brackets, optional language) are
//  acceptable by design: nothing fills without review, and the planner may
//  answer "none".
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum BlankDetector {

    /// Half-width of the context window captured around each blank, in UTF-16
    /// code units per side.
    public static let contextHalfWidth = 120

    /// One regex pattern family with an overlap-resolution priority. Higher
    /// priority wins overlaps (delimited families beat bare runs so the
    /// underscores inside {{a_b}} or [___] never double-report).
    private struct Family {
        let pattern: String
        let priority: Int
        /// Which capture group holds the label; nil means no label.
        let labelGroup: Int?
    }

    private static let families: [Family] = [
        Family(pattern: "\\[([^\\[\\]\\n]{1,60})\\]", priority: 40, labelGroup: 1),
        Family(pattern: "\\{\\{([^{}\\n]{1,60})\\}\\}", priority: 40, labelGroup: 1),
        Family(pattern: "\u{00AB}([^\u{00AB}\u{00BB}\\n]{1,60})\u{00BB}", priority: 40, labelGroup: 1),
        Family(pattern: "_{2,}", priority: 10, labelGroup: nil),
        Family(pattern: "[\u{25CF}\u{2022}]+", priority: 10, labelGroup: nil)
    ]

    /// Detect every blank in text, sorted by position. Labels that are only
    /// underscores, placeholder dots, or whitespace normalize to "".
    public static func detect(in text: String) -> [Blank] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Candidate {
            let range: NSRange
            let label: String
            let priority: Int
        }

        var candidates: [Candidate] = []
        for family in families {
            guard let regex = try? NSRegularExpression(pattern: family.pattern) else { continue }
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                var label = ""
                if let group = family.labelGroup, match.range(at: group).location != NSNotFound {
                    label = ns.substring(with: match.range(at: group))
                }
                candidates.append(Candidate(range: match.range, label: normalizeLabel(label), priority: family.priority))
            }
        }

        // Overlap resolution: higher priority first, then earlier, then longer.
        // A sweep keeps every candidate that does not intersect an already
        // accepted one.
        let ordered = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }
        var accepted: [Candidate] = []
        for candidate in ordered {
            let overlaps = accepted.contains { NSIntersectionRange($0.range, candidate.range).length > 0 }
            if !overlaps { accepted.append(candidate) }
        }

        return accepted
            .sorted { $0.range.location < $1.range.location }
            .map { candidate in
                Blank(
                    location: .textSpan(
                        start: candidate.range.location,
                        end: candidate.range.location + candidate.range.length
                    ),
                    label: candidate.label,
                    context: contextWindow(around: candidate.range, in: ns),
                    proposedFieldID: nil,
                    proposedValue: nil,
                    status: .unmatched
                )
            }
    }

    /// Labels that carry no information ([___], [●], whitespace) become "".
    private static func normalizeLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let informationless = CharacterSet(charactersIn: "_\u{25CF}\u{2022}\u{00B7}.").union(.whitespaces)
        if trimmed.unicodeScalars.allSatisfy({ informationless.contains($0) }) {
            return ""
        }
        return trimmed
    }

    private static func contextWindow(around range: NSRange, in ns: NSString) -> String {
        let start = max(0, range.location - contextHalfWidth)
        let end = min(ns.length, range.location + range.length + contextHalfWidth)
        // Clamp to grapheme boundaries so we never split a surrogate pair.
        let safeStart = ns.rangeOfComposedCharacterSequence(at: min(start, max(0, ns.length - 1))).location
        let last = max(safeStart, end - 1)
        let endSeq = ns.rangeOfComposedCharacterSequence(at: min(last, max(0, ns.length - 1)))
        let safeEnd = endSeq.location + endSeq.length
        guard ns.length > 0 else { return "" }
        return ns.substring(with: NSRange(location: safeStart, length: max(0, safeEnd - safeStart)))
    }
}
```

- [ ] **Step 4.4: Run to verify pass**

Run: `swift test --filter BlankDetectorTests 2>&1 | tail -5`
Expected: PASS. If the context-window length assertion is brittle against the grapheme clamping, loosen the assertion (assert the window contains the blank and is under 300 UTF-16 units), not the implementation.

- [ ] **Step 4.5: Commit**

```bash
git add Sources/LDACore/Engine/BlankDetector.swift Tests/LDACoreTests/BlankDetectorTests.swift
git -c commit.gpgsign=false commit -m "feat: deterministic BlankDetector for fill targets"
```

---

### Task 5: DocxFiller

**Files:**
- Create: `Sources/LDACore/IO/DocxFiller.swift`
- Test: `Tests/LDACoreTests/DocxFillTests.swift`

`DocxRedactor.redact` already applies arbitrary `Replacement.token` strings to runs, span-crossing included. Filling is the same operation with the value as the written string. The one open risk is XML escaping of values containing `&`, `<`, `>`; the restore path already writes arbitrary values into runs, so escaping should already be handled at the XML layer. The test proves it; if it fails, fix by reusing whatever `DocxRedactor.restore` uses to write values, never by hand-rolling new XML escaping.

- [ ] **Step 5.1: Write the failing tests**

Reuse the fixture helpers from `DocxIOTests.swift`. Copy the private helpers (`FixtureParagraph`, `buildDocumentXML`, `writeFixtureDocx`, `tempOutputURL`) into the new test file (they are file-private there; keep the copies private here too and note the duplication is deliberate test isolation, matching how other IO test files do it; read `HybridPdfTests.swift` first to see if a shared helper already exists and use that instead if so).

```swift
//
//  DocxFillTests.swift
//  LDACoreTests
//
//  Filling blanks in .docx drafts through DocxFiller: value lands, formatting
//  survives, offsets map through DocxImporter text, originals untouched.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxFillTests: XCTestCase {

    // ... fixture helpers copied per the note above ...

    private func blankSpan(in text: String, surface: String) -> Span {
        let ns = text as NSString
        let range = ns.range(of: surface)
        precondition(range.location != NSNotFound)
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: .unknown,
            text: surface,
            source: .manual,
            confidence: 1,
            priority: 0
        )
    }

    func testFillReplacesBracketBlankWithValue() throws {
        let docx = try writeFixtureDocx([.init(runs: ["between [Company Name], a company"])])
        let imported = try DocxImporter.importDocument(at: docx)
        let span = blankSpan(in: imported.text, surface: "[Company Name]")
        let out = tempOutputURL()
        try DocxFiller.fill(original: docx, fills: [DocxFill(span: span, value: "Acme Holdings Limited")], to: out)
        let filled = try DocxImporter.importDocument(at: out)
        XCTAssertTrue(filled.text.contains("between Acme Holdings Limited, a company"))
        XCTAssertFalse(filled.text.contains("[Company Name]"))
    }

    func testFillValueWithAmpersandSurvivesRoundTrip() throws {
        let docx = try writeFixtureDocx([.init(runs: ["supplier: [Supplier]"])])
        let imported = try DocxImporter.importDocument(at: docx)
        let span = blankSpan(in: imported.text, surface: "[Supplier]")
        let out = tempOutputURL()
        try DocxFiller.fill(original: docx, fills: [DocxFill(span: span, value: "Smith & Wesson <Asia> Ltd")], to: out)
        let filled = try DocxImporter.importDocument(at: out)
        XCTAssertTrue(filled.text.contains("Smith & Wesson <Asia> Ltd"))
    }

    func testFillMultipleBlanksAcrossParagraphs() throws {
        let docx = try writeFixtureDocx([
            .init(runs: ["this ___ day of ____"]),
            .init(runs: ["registered office at [Address]"])
        ])
        let imported = try DocxImporter.importDocument(at: docx)
        let fills = [
            DocxFill(span: blankSpan(in: imported.text, surface: "___ "), value: "10th "),
            DocxFill(span: blankSpan(in: imported.text, surface: "____"), value: "June"),
            DocxFill(span: blankSpan(in: imported.text, surface: "[Address]"), value: "1 Main Street")
        ]
        // NOTE: craft surfaces so the two underscore runs are distinct; adjust
        // the fixture text if range(of:) finds the wrong run. The point under
        // test is multiple fills across paragraphs applying at correct offsets.
        let out = tempOutputURL()
        try DocxFiller.fill(original: docx, fills: fills, to: out)
        let filled = try DocxImporter.importDocument(at: out)
        XCTAssertTrue(filled.text.contains("10th day of June"))
        XCTAssertTrue(filled.text.contains("registered office at 1 Main Street"))
    }

    func testOriginalFileUntouched() throws {
        let docx = try writeFixtureDocx([.init(runs: ["x [B] y"])])
        let before = try Data(contentsOf: docx)
        let imported = try DocxImporter.importDocument(at: docx)
        let out = tempOutputURL()
        try DocxFiller.fill(
            original: docx,
            fills: [DocxFill(span: blankSpan(in: imported.text, surface: "[B]"), value: "v")],
            to: out
        )
        XCTAssertEqual(try Data(contentsOf: docx), before)
    }

    func testRunFormattingPreserved() throws {
        // Mirror DocxIOTests.testRedactPreservesRunFormatting: build a fixture
        // whose runs carry rPr formatting, fill a blank, and assert the rPr
        // survives in the output document.xml. Copy that test's approach.
    }
}
```

Reconcile helper names with the real `DocxImporter` API (read it; the import entry point may be named differently, for example `DocxImporter.import(at:)` or a shared `DocumentImporter` protocol method) and with `FixtureParagraph`'s real shape before running.

- [ ] **Step 5.2: Run to verify failure**

Run: `swift test --filter DocxFillTests 2>&1 | tail -5`
Expected: compile FAILURE (`DocxFiller`, `DocxFill` do not exist).

- [ ] **Step 5.3: Implement `DocxFiller.swift`**

```swift
//
//  DocxFiller.swift
//  LDACore
//
//  Run-preserving blank filling for .docx targets. Filling is the same
//  span-replacement operation DocxRedactor performs for redaction, with the
//  fill value as the written string, so this stays a thin wrapper and the
//  formatting guarantees are inherited rather than reimplemented.
//
//  Offsets: DocxFill.span uses UTF-16 offsets into DocxImporter's text for the
//  SAME original file, matching the Replacement contract.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// One confirmed fill: where, and what to write.
public struct DocxFill: Equatable, Sendable {
    public var span: Span
    public var value: String

    public init(span: Span, value: String) {
        self.span = span
        self.value = value
    }
}

public enum DocxFiller {

    /// Apply confirmed fills to original and write the filled document to out.
    /// The original is never modified.
    public static func fill(original: URL, fills: [DocxFill], to out: URL) throws {
        let replacements = fills.map { Replacement(span: $0.span, token: $0.value) }
        try DocxRedactor.redact(original: original, replacements: replacements, to: out)
    }
}
```

- [ ] **Step 5.4: Run to verify pass**

Run: `swift test --filter DocxFillTests 2>&1 | tail -5`
Expected: PASS. If the ampersand test fails, inspect how `DocxRedactor.restore` writes values into runs and route the fill through the same escaping path; do not write custom escaping in DocxFiller.

- [ ] **Step 5.5: Commit**

```bash
git add Sources/LDACore/IO/DocxFiller.swift Tests/LDACoreTests/DocxFillTests.swift
git -c commit.gpgsign=false commit -m "feat: DocxFiller fills blanks via run-preserving replacement"
```

---

### Task 6: AcroFormFiller

**Files:**
- Create: `Sources/LDACore/IO/AcroFormFiller.swift`
- Test: `Tests/LDACoreTests/AcroFormFillTests.swift`

- [ ] **Step 6.1: Write the failing tests**

Build the fixture PDF programmatically with PDFKit (no committed binaries): one page, two text widgets (`CompanyName`, `RegNumber`), one checkbox widget (`Agree`).

```swift
//
//  AcroFormFillTests.swift
//  LDACoreTests
//
//  AcroForm enumeration and text-widget filling. Fixtures are built
//  programmatically with PDFKit in the temporary directory.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
@testable import LDACore

final class AcroFormFillTests: XCTestCase {

    private func makeFormPDF() throws -> URL {
        let page = PDFPage()
        func widget(_ name: String, _ kind: PDFAnnotationWidgetSubtype, rect: CGRect) -> PDFAnnotation {
            let annotation = PDFAnnotation(
                bounds: rect,
                forType: .widget,
                withProperties: nil
            )
            annotation.widgetFieldType = kind
            annotation.fieldName = name
            return annotation
        }
        page.addAnnotation(widget("CompanyName", .text, rect: CGRect(x: 50, y: 700, width: 300, height: 20)))
        page.addAnnotation(widget("RegNumber", .text, rect: CGRect(x: 50, y: 660, width: 300, height: 20)))
        let checkbox = widget("Agree", .button, rect: CGRect(x: 50, y: 620, width: 20, height: 20))
        checkbox.widgetControlType = .checkBoxControl
        page.addAnnotation(checkbox)

        let document = PDFDocument()
        document.insert(page, at: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        guard document.write(to: url) else { throw NSError(domain: "fixture", code: 1) }
        return url
    }

    func testEnumerateFindsTextWidgetsAndManualWidgets() throws {
        let url = try makeFormPDF()
        let form = try AcroFormFiller.enumerate(at: url)
        XCTAssertEqual(Set(form.textFieldNames), ["CompanyName", "RegNumber"])
        XCTAssertEqual(form.manualWidgetNames, ["Agree"])
    }

    func testFillWritesValuesToNewFileAndOriginalUntouched() throws {
        let url = try makeFormPDF()
        let before = try Data(contentsOf: url)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try AcroFormFiller.fill(
            original: url,
            values: ["CompanyName": "Acme Holdings Limited", "RegNumber": "1234567"],
            to: out
        )
        XCTAssertEqual(try Data(contentsOf: url), before)

        let reread = PDFDocument(url: out)!
        var found: [String: String] = [:]
        for pageIndex in 0..<reread.pageCount {
            for annotation in reread.page(at: pageIndex)!.annotations
            where annotation.widgetFieldType == .text {
                found[annotation.fieldName ?? ""] = annotation.widgetStringValue
            }
        }
        XCTAssertEqual(found["CompanyName"], "Acme Holdings Limited")
        XCTAssertEqual(found["RegNumber"], "1234567")
    }

    func testFillUnknownFieldNameThrowsStaleTarget() throws {
        let url = try makeFormPDF()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        XCTAssertThrowsError(
            try AcroFormFiller.fill(original: url, values: ["Vanished": "x"], to: out)
        ) { error in
            guard case AcroFormFiller.FillError.staleTarget(let missing) = error else {
                return XCTFail("expected staleTarget, got \(error)")
            }
            XCTAssertEqual(missing, ["Vanished"])
        }
    }

    func testNonFormPDFReportsNoFields() throws {
        // A page with no widgets: enumerate returns empty lists, not an error.
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        XCTAssertTrue(document.write(to: url))
        let form = try AcroFormFiller.enumerate(at: url)
        XCTAssertTrue(form.textFieldNames.isEmpty)
        XCTAssertTrue(form.manualWidgetNames.isEmpty)
    }
}
```

PDFKit reconciliation notes for the executor: a bare `PDFPage()` may need a sized media box to accept annotations; if `PDFAnnotation(bounds:forType:withProperties:)` plus `widgetFieldType` does not persist through `write(to:)` on this macOS version, set the annotation properties via the keyed approach used elsewhere in the codebase or construct with a properties dictionary (`PDFAnnotationKey`). Adjust the fixture builder until the round-trip test is meaningful; the assertions are the contract. Also note PDFKit treats same-named widgets across pages as one logical field: the `values: [String: String]` dictionary is the right shape, but do not write tests that assume field names are unique per page, and filling one name may update several widgets (that is correct AcroForm behavior).

- [ ] **Step 6.2: Run to verify failure**

Run: `swift test --filter AcroFormFillTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 6.3: Implement `AcroFormFiller.swift`**

```swift
//
//  AcroFormFiller.swift
//  LDACore
//
//  AcroForm support for fill targets: enumerate widgets (text widgets are
//  fillable in V1; checkbox, radio, and choice widgets are reported as manual
//  items) and write confirmed values to a NEW file. The original is never
//  modified.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import PDFKit

public enum AcroFormFiller {

    /// What enumeration found in a form PDF.
    public struct FormInventory: Equatable, Sendable {
        /// Names of text widgets, in page order then annotation order.
        public var textFieldNames: [String]
        /// Per-field nearby context: the field name plus tooltip text when
        /// present (used as the matching label downstream).
        public var fieldLabels: [String: String]
        /// Widgets V1 does not auto-fill (checkbox, radio, choice).
        public var manualWidgetNames: [String]
    }

    public enum FillError: Error, Equatable {
        /// The document could not be opened as a PDF.
        case unreadable
        /// Field names in the plan no longer exist in the target.
        case staleTarget(missing: [String])
        /// PDFKit refused to write the filled document (for example a
        /// permissions-locked file).
        case writeFailed
    }

    public static func enumerate(at url: URL) throws -> FormInventory {
        guard let document = PDFDocument(url: url) else { throw FillError.unreadable }
        var text: [String] = []
        var labels: [String: String] = [:]
        var manual: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                let name = annotation.fieldName ?? ""
                guard !name.isEmpty else { continue }
                if annotation.widgetFieldType == .text {
                    text.append(name)
                    let tooltip = annotation.toolTip ?? ""
                    labels[name] = tooltip.isEmpty ? name : "\(name) \(tooltip)"
                } else {
                    manual.append(name)
                }
            }
        }
        return FormInventory(textFieldNames: text, fieldLabels: labels, manualWidgetNames: manual)
    }

    /// Write values into the named text widgets and save to out. AcroForm
    /// treats same-named widgets as one logical field, so the value is written
    /// to EVERY matching widget, not just the first.
    public static func fill(original: URL, values: [String: String], to out: URL) throws {
        guard let document = PDFDocument(url: original) else { throw FillError.unreadable }

        var filledNames: Set<String> = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations
            where annotation.widgetFieldType == .text {
                guard let name = annotation.fieldName, let value = values[name] else { continue }
                annotation.widgetStringValue = value
                filledNames.insert(name)
            }
        }
        let missing = Set(values.keys).subtracting(filledNames)
        guard missing.isEmpty else {
            throw FillError.staleTarget(missing: missing.sorted())
        }
        guard document.write(to: out) else { throw FillError.writeFailed }
    }
}
```

- [ ] **Step 6.4: Run to verify pass**

Run: `swift test --filter AcroFormFillTests 2>&1 | tail -5`
Expected: PASS (after fixture reconciliation per the notes).

- [ ] **Step 6.5: Commit**

```bash
git add Sources/LDACore/IO/AcroFormFiller.swift Tests/LDACoreTests/AcroFormFillTests.swift
git -c commit.gpgsign=false commit -m "feat: AcroFormFiller enumerates and fills text widgets"
```

---

### Task 7: Prompts for profile extraction and blank matching

**Files:**
- Modify: `Sources/LDACore/Engine/PromptStore.swift`
- Test: extend `Tests/LDACoreTests/PromptStoreTests.swift`

- [ ] **Step 7.1: Read `PromptStore.swift` and `PromptStoreTests.swift` fully.** Note exactly how `PromptKind.extraction` is wired: default constant, `current...` var, `reset`, `validate`, the user-prompt builder `extractionUser(chunk:)`, and whether `PromptSnapshot` carries it. Mirror that wiring for the two new kinds. If `PromptSnapshot` includes extraction, add the new bodies as OPTIONAL fields with decode defaults so previously persisted snapshots still decode; if it does not, leave snapshot untouched.

- [ ] **Step 7.2: Write failing tests** (extend the existing test class with the same style used for extraction):

```swift
func testProfilePromptDefaultsCarryJSONContractAndKeys() {
    let store = PromptStore()
    XCTAssertTrue(store.currentProfileSystem.contains("JSON"))
    for key in ["companyName", "companyNumber", "incorporationDate", "registeredOffice"] {
        XCTAssertTrue(store.currentProfileSystem.contains(key), "missing \(key)")
    }
    let user = store.profileUser(documentName: "cert.pdf", chunk: "TEXT HERE")
    XCTAssertTrue(user.contains("TEXT HERE"))
    XCTAssertTrue(user.contains("cert.pdf"))
}

func testBlankMatchPromptCarriesCatalogAndBlanks() {
    let store = PromptStore()
    XCTAssertTrue(store.currentBlankMatchSystem.contains("JSON"))
    let user = store.blankMatchUser(
        catalog: "1. companyName: Acme Holdings Limited",
        blanks: "B1 label: \"\" context: \"this ___ day\""
    )
    XCTAssertTrue(user.contains("Acme Holdings Limited"))
    XCTAssertTrue(user.contains("this ___ day"))
}

func testResetRestoresProfileAndBlankMatchDefaults() {
    let store = PromptStore()
    store.currentProfileSystem = "edited"
    store.currentBlankMatchSystem = "edited"
    store.reset(.profile)
    store.reset(.blankMatch)
    XCTAssertEqual(store.currentProfileSystem, PromptStore.defaultProfileSystem)
    XCTAssertEqual(store.currentBlankMatchSystem, PromptStore.defaultBlankMatchSystem)
}
```

- [ ] **Step 7.3: Run to verify failure**

Run: `swift test --filter PromptStoreTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 7.4: Implement.** Add `case profile` and `case blankMatch` to `PromptKind`; add the two defaults; add `currentProfileSystem` / `currentBlankMatchSystem`; wire `reset` and (if applicable) snapshot with optional decode defaults; add the user builders.

Default profile system prompt (English instruction body; works for English and Chinese sources):

```swift
public static let defaultProfileSystem: String = """
You extract company facts from incorporation documents (certificates of \
incorporation, articles of association, business licenses). The document may \
be in English or Chinese; extract facts regardless of language.

Return RAW JSON ONLY, no code fences, no commentary: an array of objects, \
each {"key": string, "value": string, "snippet": string, "confidence": number}.

Allowed keys: companyName, companyNameLocal, formerName, entityKind, \
jurisdiction, companyNumber, incorporationDate, registeredOffice, \
authorizedCapital, issuedCapital, parValue, shareClass, directorName, \
shareholderName, shareholderShares, companySecretary, registeredAgent. \
If you find an important fact that fits none of these, use a short lowercase \
key of your own.

Rules:
- "value" is the exact fact as written in the document. Do not translate, \
reformat, or abbreviate it.
- "snippet" is the EXACT sentence or line from the document containing the \
value, copied verbatim.
- "confidence" is between 0 and 1.
- One object per fact. Repeat keys for lists (several directors, several \
shareholders).
- shareholderShares values must name the shareholder, for example \
"Jane Roe: 9,000 ordinary shares".
- If the chunk contains no extractable fact, return [].
"""

public func profileUser(documentName: String, chunk: String) -> String {
    "Document: \(documentName)\n\nText:\n\(chunk)"
}
```

Default blank-match system prompt:

```swift
public static let defaultBlankMatchSystem: String = """
You match blanks in a legal draft to fields from a company profile. You are \
given a numbered field catalog (key and value) and a numbered list of blanks, \
each with a label and the surrounding text.

Return RAW JSON ONLY, no code fences: an array of objects, each \
{"blank": number, "field": number or null, "value": string or null}.

Rules:
- "blank" is the blank's number from the list.
- "field" is the catalog number of the matching field, or null when no \
catalog field fits. Never guess: if the context calls for a fact the catalog \
does not contain (for example the counterparty's name), answer null.
- "value" is OPTIONAL: provide it only when the blank needs a reformatted \
form of the field value (for example the day, month, or year part of a date, \
or a spelled-out form the context requires). When the canonical value fits \
as written, leave "value" null.
- Answer every blank exactly once.
"""

public func blankMatchUser(catalog: String, blanks: String) -> String {
    "Field catalog:\n\(catalog)\n\nBlanks:\n\(blanks)"
}
```

- [ ] **Step 7.5: Run to verify pass, plus the whole PromptStore suite**

Run: `swift test --filter PromptStoreTests 2>&1 | tail -5`
Expected: PASS, including pre-existing cases.

- [ ] **Step 7.6: Commit**

```bash
git add Sources/LDACore/Engine/PromptStore.swift Tests/LDACoreTests/PromptStoreTests.swift
git -c commit.gpgsign=false commit -m "feat: profile extraction and blank match prompts"
```

---

### Task 8: ProfileJSONParser

**Files:**
- Create: `Sources/LDACore/Engine/ProfileJSONParser.swift`
- Test: `Tests/LDACoreTests/ProfileJSONParserTests.swift`

- [ ] **Step 8.1: Read `EntityJSONParser.swift` fully** and mirror its defensive salvage approach (fence stripping, locating the outermost JSON array, tolerating trailing junk). Reuse its private helpers by generalizing them ONLY if they are trivially reusable; otherwise keep the new parser self-contained.

- [ ] **Step 8.2: Write failing tests**

```swift
//
//  ProfileJSONParserTests.swift
//  LDACoreTests
//
//  Defensive parsing of the profile extraction and blank match model output.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ProfileJSONParserTests: XCTestCase {

    func testParsesCleanProfileArray() {
        let output = """
        [{"key": "companyName", "value": "Acme Holdings Limited", "snippet": "the name of the company is Acme Holdings Limited", "confidence": 0.95}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "companyName")
        XCTAssertEqual(rows[0].value, "Acme Holdings Limited")
        XCTAssertEqual(rows[0].confidence, 0.95, accuracy: 0.0001)
    }

    func testStripsCodeFencesAndProse() {
        let output = """
        Sure, here is the JSON:
        ```json
        [{"key": "companyNumber", "value": "1234567", "snippet": "No. 1234567", "confidence": 0.9}]
        ```
        """
        XCTAssertEqual(ProfileJSONParser.parseProfileRows(output).count, 1)
    }

    func testRowsMissingRequiredFieldsDropped() {
        let output = """
        [{"key": "companyName"}, {"value": "x", "snippet": "x", "confidence": 1}, {"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong", "confidence": 0.8}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.map(\.key), ["jurisdiction"])
    }

    func testUnparseableReturnsNil() {
        XCTAssertNil(ProfileJSONParser.parseProfileRowsDetailed("no json here at all"))
        XCTAssertNil(ProfileJSONParser.parseProfileRowsDetailed("[{\"key\": \"companyName\", truncated"))
    }

    func testParsesBlankMatchRows() {
        let output = """
        [{"blank": 1, "field": 2, "value": null}, {"blank": 2, "field": null, "value": null}, {"blank": 3, "field": 1, "value": "10th"}]
        """
        let rows = ProfileJSONParser.parseBlankMatchRows(output)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].blank, 1)
        XCTAssertEqual(rows[0].field, 2)
        XCTAssertNil(rows[0].value)
        XCTAssertNil(rows[1].field)
        XCTAssertEqual(rows[2].value, "10th")
    }
}
```

- [ ] **Step 8.3: Run to verify failure**

Run: `swift test --filter ProfileJSONParserTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 8.4: Implement `ProfileJSONParser.swift`**

```swift
//
//  ProfileJSONParser.swift
//  LDACore
//
//  Defensive parsing of model output for profile extraction and blank
//  matching, in the same salvage style as EntityJSONParser: strip code fences
//  and prose, locate the outermost JSON array, decode row by row, and drop
//  malformed rows instead of failing the batch. The Detailed variants return
//  nil when no JSON array can be recovered at all, which the callers treat as
//  a truncation signal (retry, then split, then mark incomplete).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// One raw extracted profile row before grounding and merging.
public struct ProfileRow: Equatable, Sendable {
    public let key: String
    public let value: String
    public let snippet: String
    public let confidence: Double
}

/// One raw blank match answer.
public struct BlankMatchRow: Equatable, Sendable {
    public let blank: Int
    public let field: Int?
    public let value: String?
}

public enum ProfileJSONParser {

    /// Salvage-parse profile rows. Returns [] when an array was found but had
    /// no valid rows. Convenience over parseProfileRowsDetailed.
    public static func parseProfileRows(_ modelOutput: String) -> [ProfileRow] {
        parseProfileRowsDetailed(modelOutput) ?? []
    }

    /// Returns nil when no JSON array could be recovered (truncation signal).
    public static func parseProfileRowsDetailed(_ modelOutput: String) -> [ProfileRow]? {
        guard let array = jsonArray(in: modelOutput) else { return nil }
        var rows: [ProfileRow] = []
        for element in array {
            guard
                let object = element as? [String: Any],
                let key = object["key"] as? String, !key.isEmpty,
                let value = object["value"] as? String, !value.isEmpty,
                let snippet = object["snippet"] as? String
            else { continue }
            let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            rows.append(ProfileRow(
                key: key,
                value: value,
                snippet: snippet,
                confidence: min(1, max(0, confidence))
            ))
        }
        return rows
    }

    public static func parseBlankMatchRows(_ modelOutput: String) -> [BlankMatchRow] {
        parseBlankMatchRowsDetailed(modelOutput) ?? []
    }

    public static func parseBlankMatchRowsDetailed(_ modelOutput: String) -> [BlankMatchRow]? {
        guard let array = jsonArray(in: modelOutput) else { return nil }
        var rows: [BlankMatchRow] = []
        for element in array {
            guard
                let object = element as? [String: Any],
                let blank = (object["blank"] as? NSNumber)?.intValue
            else { continue }
            let field = (object["field"] as? NSNumber)?.intValue
            let value = object["value"] as? String
            rows.append(BlankMatchRow(blank: blank, field: field, value: value))
        }
        return rows
    }

    /// Strip fences and prose, then decode the outermost JSON array found
    /// between the first "[" and the last "]".
    private static func jsonArray(in modelOutput: String) -> [Any]? {
        var text = modelOutput
        text = text.replacingOccurrences(of: "```json", with: "")
        text = text.replacingOccurrences(of: "```", with: "")
        guard
            let start = text.firstIndex(of: "["),
            let end = text.lastIndex(of: "]"),
            start < end
        else { return nil }
        let slice = String(text[start...end])
        guard
            let data = slice.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let array = parsed as? [Any]
        else { return nil }
        return array
    }
}
```

- [ ] **Step 8.5: Run to verify pass**

Run: `swift test --filter ProfileJSONParserTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 8.6: Commit**

```bash
git add Sources/LDACore/Engine/ProfileJSONParser.swift Tests/LDACoreTests/ProfileJSONParserTests.swift
git -c commit.gpgsign=false commit -m "feat: defensive ProfileJSONParser for profile and blank match output"
```

---

### Task 9: ProfileExtractor

**Files:**
- Create: `Sources/LDACore/Engine/ProfileExtractor.swift`
- Test: `Tests/LDACoreTests/ProfileExtractorTests.swift`

**Behavior contract:**
1. For each source document (name + already-imported text): chunk with `Chunker.chunk(text)` (defaults).
2. For each chunk: build the prompt with `PromptStore` (`defaultProfileSystem` semantics) and the chat scaffold the way `LLMExtractor` does (read `LLMExtractor.swift` and reuse its prompt assembly helper or replicate its use of `LLMEngine.buildChatMLPrompt(system:user:)`); call `completer.complete`.
3. Parse with `ProfileJSONParser.parseProfileRowsDetailed`. On nil (no JSON recovered): retry once with a doubled `maxTokens`; if still nil, split the chunk in half (UTF-16 midpoint clamped to a grapheme boundary) and process the halves once each; any half still failing increments `incompleteSegmentCount` and is skipped.
4. Ground each row: `sourceText.range(of: snippet, options: [.caseInsensitive])` found means `snippetVerified = true`; not found means `snippetVerified = false` and confidence capped at 0.4.
5. Map row keys through `ProfileFieldKey(rawKey:)`, EXCEPT bare model keys (no `custom:` prefix arrives from the model): unknown raw strings already fall through to `.custom`, which is correct.
6. Merge: drop a row when an existing kept field has the same key and the same normalized value (keep the higher-confidence one); otherwise append.
7. Result type: `ProfileExtractionResult { fields: [ProfileField], incompleteSegmentCount: Int }`. The caller (facade) assembles `CompanyProfile` and sets `incomplete = incompleteSegmentCount > 0`.
8. Progress callback `(segmentsDone, segmentsTotal)` like `LLMExtractor`.

- [ ] **Step 9.1: Write failing tests** with a scripted fake completer (mirror the fake in `LLMExtractorTests.swift`; read it first and reuse its shape):

```swift
final class ProfileExtractorTests: XCTestCase {

    /// A fake completer returning queued responses; records prompts.
    private final class FakeCompleter: TextCompleter {
        var queue: [String]
        var prompts: [String] = []
        var maxTokensSeen: [Int?] = []
        init(_ queue: [String]) { self.queue = queue }
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            prompts.append(prompt)
            maxTokensSeen.append(maxTokens)
            return queue.isEmpty ? "[]" : queue.removeFirst()
        }
    }

    private func row(_ key: String, _ value: String, snippet: String, confidence: Double = 0.9) -> String {
        "{\"key\": \"\(key)\", \"value\": \"\(value)\", \"snippet\": \"\(snippet)\", \"confidence\": \(confidence)}"
    }

    func testExtractsGroundedField() throws {
        let text = "I certify that the name of the company is Acme Holdings Limited."
        let fake = FakeCompleter(["[\(row("companyName", "Acme Holdings Limited", snippet: "the name of the company is Acme Holdings Limited"))]"])
        let extractor = ProfileExtractor(completer: fake)
        let result = try extractor.extract(sources: [("cert.pdf", text)])
        XCTAssertEqual(result.fields.count, 1)
        XCTAssertEqual(result.fields[0].key, .companyName)
        XCTAssertTrue(result.fields[0].snippetVerified)
        XCTAssertEqual(result.fields[0].sourceDocument, "cert.pdf")
        XCTAssertEqual(result.incompleteSegmentCount, 0)
    }

    func testUngroundedSnippetCapsConfidence() throws {
        let text = "irrelevant text"
        let fake = FakeCompleter(["[\(row("companyName", "Acme", snippet: "not in the document", confidence: 0.95))]"])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", text)])
        XCTAssertFalse(result.fields[0].snippetVerified)
        XCTAssertLessThanOrEqual(result.fields[0].confidence, 0.4)
    }

    func testDuplicateAcrossDocumentsDeduped() throws {
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited"))]",
            "[\(row("companyName", "ACME HOLDINGS  LIMITED", snippet: "ACME HOLDINGS  LIMITED"))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [
            ("cert.pdf", "Acme Holdings Limited"),
            ("articles.pdf", "ACME HOLDINGS  LIMITED")
        ])
        XCTAssertEqual(result.fields.filter { $0.key == .companyName }.count, 1)
    }

    func testConflictingValuesBothKept() throws {
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited"))]",
            "[\(row("companyName", "Acme Holdings (HK) Limited", snippet: "Acme Holdings (HK) Limited"))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [
            ("cert.pdf", "Acme Holdings Limited"),
            ("articles.pdf", "Acme Holdings (HK) Limited")
        ])
        XCTAssertEqual(result.fields.filter { $0.key == .companyName }.count, 2)
    }

    func testUnparseableRetriesThenSplitsThenMarksIncomplete() throws {
        // Five garbage responses: initial, retry, split half 1, half 1 retry?
        // Read the implementation contract: initial fails, retry fails, split
        // into two halves, each half gets ONE attempt; both fail here.
        let fake = FakeCompleter(["garbage", "garbage", "garbage", "garbage"])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", "short doc")])
        XCTAssertEqual(result.fields.count, 0)
        XCTAssertGreaterThan(result.incompleteSegmentCount, 0)
    }

    func testRetryDoublesMaxTokens() throws {
        let fake = FakeCompleter(["garbage", "[]"])
        _ = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", "short doc")])
        XCTAssertEqual(fake.maxTokensSeen.count, 2)
        if let first = fake.maxTokensSeen[0], let second = fake.maxTokensSeen[1] {
            XCTAssertEqual(second, first * 2)
        } else {
            XCTFail("expected explicit maxTokens on both calls")
        }
    }

    func testUnknownKeyBecomesCustomField() throws {
        let text = "seal number 778899"
        let fake = FakeCompleter(["[\(row("sealNumber", "778899", snippet: "seal number 778899"))]"])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", text)])
        XCTAssertEqual(result.fields[0].key, .custom("sealNumber"))
    }
}
```

- [ ] **Step 9.2: Run to verify failure** (`swift test --filter ProfileExtractorTests`), expected compile FAILURE.

- [ ] **Step 9.3: Implement `ProfileExtractor.swift`** per the behavior contract. Shape:

```swift
public struct ProfileExtractionResult: Sendable {
    public let fields: [ProfileField]
    public let incompleteSegmentCount: Int
}

public final class ProfileExtractor {
    public static let defaultMaxTokens = 1024
    public static let ungroundedConfidenceCap = 0.4

    private let completer: TextCompleter
    private let prompts: PromptStore

    public init(completer: TextCompleter, prompts: PromptStore = PromptStore()) { ... }

    /// sources: (documentName, importedText) pairs.
    public func extract(
        sources: [(name: String, text: String)],
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ProfileExtractionResult { ... }
}
```

Implementation notes: count total segments first (sum of chunk counts) for the progress callback; assemble prompts exactly the way `LLMExtractor` does (same ChatML builder and stop tokens) so the thinking-off behavior is inherited; throwing completer errors propagate (the facade maps them).

- [ ] **Step 9.4: Run to verify pass** (`swift test --filter ProfileExtractorTests`), expected PASS.

- [ ] **Step 9.5: Commit**

```bash
git add Sources/LDACore/Engine/ProfileExtractor.swift Tests/LDACoreTests/ProfileExtractorTests.swift
git -c commit.gpgsign=false commit -m "feat: ProfileExtractor with grounding, merge, and incomplete marking"
```

---

### Task 10: FillPlanner

**Files:**
- Create: `Sources/LDACore/Engine/FillPlanner.swift`
- Test: `Tests/LDACoreTests/FillPlannerTests.swift`

**Behavior contract:**
1. Input: `[Blank]` (from BlankDetector or AcroForm inventory mapped to Blanks), `CompanyProfile`, optional `TextCompleter`.
2. Synonym pass (no model): normalize the label (lowercase, strip a leading "insert " / "enter " / "please insert ", strip "the ", strip "name of ", collapse whitespace, strip trailing ":" and "："), look up in the synonym table. On hit with exactly ONE field holding that key: status `.proposed`, `proposedFieldID` set, `proposedValue = field.value`. On hit with SEVERAL fields (directors): status `.proposed`, `proposedFieldID = nil`, `proposedValue = nil` (the UI presents the picker; CLI plan prints the candidates).
3. Synonym table (initial, grows over time): companyName: "company name", "name of company", "corporate name", "company", "公司名称", "公司名稱"; companyNameLocal: "chinese name", "local name", "中文名称"; jurisdiction: "jurisdiction", "place of incorporation", "state of incorporation", "管辖法域", "注册地"; companyNumber: "company number", "registration number", "registration no", "reg no", "certificate number", "统一社会信用代码", "注册号"; incorporationDate: "date of incorporation", "incorporation date", "date of registration", "成立日期", "注册日期"; registeredOffice: "registered office", "registered address", "registered office address", "注册地址", "注册办事处"; authorizedCapital: "authorized capital", "authorised capital", "注册资本"; issuedCapital: "issued capital", "issued share capital"; parValue: "par value", "nominal value", "面值"; directorName: "director", "director name", "name of director", "董事", "董事姓名"; shareholderName: "shareholder", "member", "股东", "股东姓名"; companySecretary: "company secretary", "secretary", "公司秘书"; registeredAgent: "registered agent", "注册代理人"; entityKind: "entity type", "company type", "公司类型".
4. Model fallback (only when a completer is supplied): batch ALL still-unmatched blanks into ONE call (batches of at most 12 blanks per call when more): numbered catalog of profile fields, numbered blanks with label and context, `blankMatchUser` prompt, parse with `parseBlankMatchRows`. Valid `field` index: status `.proposed` with that field's id and `value ?? field.value`. Null field or invalid index: `.unmatched`. Parse failure of the whole batch: leave the batch `.unmatched` (matching is best-effort; no incomplete flag here).
5. No completer: unmatched blanks just stay `.unmatched`.
6. Pure function of inputs plus completer output; no clock, no randomness.

- [ ] **Step 10.1: Write failing tests** (same FakeCompleter shape as Task 9):

```swift
final class FillPlannerTests: XCTestCase {

    private func profile(_ fields: [ProfileField]) -> CompanyProfile {
        CompanyProfile(label: "x", fields: fields, sourceDocuments: [], createdAtISO8601: "2026-06-10T00:00:00Z", incomplete: false)
    }

    private func field(_ key: ProfileFieldKey, _ value: String) -> ProfileField {
        ProfileField(key: key, value: value, sourceDocument: "cert.pdf", sourceSnippet: value, snippetVerified: true, confidence: 0.9, userEdited: false)
    }

    private func blank(_ label: String, context: String = "") -> Blank {
        Blank(location: .textSpan(start: 0, end: 1), label: label, context: context, proposedFieldID: nil, proposedValue: nil, status: .unmatched)
    }

    func testSynonymMatchProposesCanonicalValue() {
        let companyField = field(.companyName, "Acme Holdings Limited")
        let planned = FillPlanner.plan(blanks: [blank("Company Name")], profile: profile([companyField]), completer: nil)
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertEqual(planned[0].proposedFieldID, companyField.id)
        XCTAssertEqual(planned[0].proposedValue, "Acme Holdings Limited")
    }

    func testNormalizationStripsInsertAndColonAndCase() {
        let dateField = field(.incorporationDate, "10 June 2026")
        for label in ["Insert Date of Incorporation", "date of incorporation:", "DATE OF INCORPORATION"] {
            let planned = FillPlanner.plan(blanks: [blank(label)], profile: profile([dateField]), completer: nil)
            XCTAssertEqual(planned[0].status, .proposed, "label \(label)")
        }
    }

    func testChineseLabelMatches() {
        let planned = FillPlanner.plan(blanks: [blank("公司名称")], profile: profile([field(.companyName, "Acme")]), completer: nil)
        XCTAssertEqual(planned[0].status, .proposed)
    }

    func testAmbiguousMultiFieldKeyProposesWithoutPick() {
        let directors = [field(.directorName, "Jane Roe"), field(.directorName, "John Doe")]
        let planned = FillPlanner.plan(blanks: [blank("Director")], profile: profile(directors), completer: nil)
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertNil(planned[0].proposedFieldID)
        XCTAssertNil(planned[0].proposedValue)
    }

    func testNoCompleterLeavesUnlabeledUnmatched() {
        let planned = FillPlanner.plan(blanks: [blank("")], profile: profile([field(.companyName, "Acme")]), completer: nil)
        XCTAssertEqual(planned[0].status, .unmatched)
    }

    func testModelFallbackMatchesAndAdaptsValue() {
        let dateField = field(.incorporationDate, "10 June 2026")
        let fake = FakeCompleter(["[{\"blank\": 1, \"field\": 1, \"value\": \"10th\"}]"])
        let planned = FillPlanner.plan(
            blanks: [blank("", context: "this ___ day of June")],
            profile: profile([dateField]),
            completer: fake
        )
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertEqual(planned[0].proposedFieldID, dateField.id)
        XCTAssertEqual(planned[0].proposedValue, "10th")
    }

    func testModelNullAnswerStaysUnmatched() {
        let fake = FakeCompleter(["[{\"blank\": 1, \"field\": null, \"value\": null}]"])
        let planned = FillPlanner.plan(blanks: [blank("", context: "counterparty name ___")], profile: profile([field(.companyName, "Acme")]), completer: fake)
        XCTAssertEqual(planned[0].status, .unmatched)
    }

    func testModelInvalidFieldIndexStaysUnmatched() {
        let fake = FakeCompleter(["[{\"blank\": 1, \"field\": 99, \"value\": null}]"])
        let planned = FillPlanner.plan(blanks: [blank("")], profile: profile([field(.companyName, "Acme")]), completer: fake)
        XCTAssertEqual(planned[0].status, .unmatched)
    }

    func testBatchSplitsAtTwelveBlanks() {
        let blanks = (0..<13).map { blank("", context: "ctx \($0)") }
        let fake = FakeCompleter(["[]", "[]"])
        _ = FillPlanner.plan(blanks: blanks, profile: profile([field(.companyName, "Acme")]), completer: fake)
        XCTAssertEqual(fake.prompts.count, 2)
    }
}
```

- [ ] **Step 10.2: Run to verify failure**, expected compile FAILURE.

- [ ] **Step 10.3: Implement `FillPlanner.swift`** per the contract. Public surface:

```swift
public enum FillPlanner {
    public static let modelBatchSize = 12

    /// Returns the blanks with proposals applied. Pure given the completer.
    public static func plan(
        blanks: [Blank],
        profile: CompanyProfile,
        completer: TextCompleter?,
        prompts: PromptStore = PromptStore()
    ) -> [Blank]
}
```

- [ ] **Step 10.4: Run to verify pass.**

- [ ] **Step 10.5: Commit**

```bash
git add Sources/LDACore/Engine/FillPlanner.swift Tests/LDACoreTests/FillPlannerTests.swift
git -c commit.gpgsign=false commit -m "feat: FillPlanner with synonym table and batched model fallback"
```

---

### Task 11: LDAService facade operations

**Files:**
- Modify: `Sources/LDACore/Service/LDAService.swift`
- Test: `Tests/LDACoreTests/FillServiceTests.swift`

**Read `LDAService.swift` fully first.** Reuse its private `importDocument` by dropping `private` (make it internal), and follow the established error and progress conventions.

**New facade surface (mirror existing parameter conventions exactly):**

```swift
/// The outcome of extractProfile: the profile plus per-source import
/// failures (spec section 9: a failing source is named, the others still
/// contribute).
public struct ExtractProfileResult: Sendable {
    public var profile: CompanyProfile
    /// (file name, reason) for every source that could not be imported.
    public var failedSources: [(name: String, reason: String)]
}

/// Build a CompanyProfile from source documents using the on-device model.
/// modelPath is REQUIRED (profile extraction is a model feature by nature).
/// Throws only when NO source imports; otherwise failed sources are
/// reported in the result and the readable ones contribute.
public static func extractProfile(
    sources: [URL],
    label: String,
    modelPath: String,
    createdAtISO8601: String,
    onProgress: ((Int, Int) -> Void)? = nil
) throws -> ExtractProfileResult

/// Detect blanks in target and propose fills from profile. modelPath nil
/// means deterministic-only matching. For DOCX targets the returned plan's
/// blanks carry text spans into the imported text; recompute at apply time.
public static func planFill(
    target: URL,
    profile: CompanyProfile,
    modelPath: String?
) throws -> FillPlan

/// Apply the CONFIRMED blanks of plan to target, writing the filled document
/// and returning a value-free report. outputDir receives
/// "<stem> (filled).<ext>". Throws outputEqualsInput-style validation errors
/// consistent with the existing operations.
public static func applyFill(
    plan: FillPlan,
    target: URL,
    profile: CompanyProfile,
    outputDir: URL
) throws -> FillReport
```

**Behavior:**
- `extractProfile`: import each source (`importDocument`) individually, COLLECTING failures instead of aborting: an unreadable source (or OCR yielding no text) lands in `failedSources` with its file name and a reason, and the remaining sources still contribute (spec section 9). Throw only when zero sources import (add a `case noReadableSources` to `LDAServiceError` if no existing case fits). Then construct ONE `LLMEngine` from `modelPath` (reuse however `anonymize` constructs its engine for the LLM pass; read and mirror, including `Config` defaults); run `ProfileExtractor` over the readable sources; assemble `CompanyProfile` (label, fields, readable source file names, caller timestamp, `incomplete` flag) and return it with `failedSources`.
- `planFill`: switch on file extension the way `importDocument` does. DOCX ONLY for text targets: import, `BlankDetector.detect`, then `FillPlanner.plan` (completer built only when `modelPath` is non-nil). TXT, Markdown, and every other non-docx, non-pdf extension is NOT a fill target (spec non-goals); `planFill` guards BEFORE import and throws `DocumentIOError.unsupportedFormat` (defined in `IOTypes.swift`; CLI, MCP, and ReviewModel already map it to user-facing messages). Note `importDocument` itself deliberately treats unknown extensions as plain text and never throws this, which is why the guard lives in `planFill`. TXT remains valid as a profile SOURCE in `extractProfile`. PDF: `AcroFormFiller.enumerate`; map each text field to a `Blank(location: .acroFormField(name:), label: inventory.fieldLabels[name] ?? name, context: "")` (leave a one-line comment that empty context is a deliberate V1 choice: nearby page text was judged not cheaply available); planner runs the same way; `manualWidgetNames` flow into the plan. A PDF with no widgets at all returns an empty-blanks plan (the UI shows the empty state; flat-PDF filling is out of scope).
- `applyFill`: filter `plan.blanks` to `.confirmed` with a non-nil `proposedValue`. DOCX: re-import target, verify each text-span blank's surface text is unchanged (substring at the span equals what the plan captured implicitly; verify by bounds within text length AND the span surface still matching a blank pattern via `BlankDetector.detect` containment; on mismatch throw a stale-target error consistent with `AcroFormFiller.FillError.staleTarget` semantics but as an `LDAServiceError` case `staleTarget`); build `DocxFill`s; `DocxFiller.fill`. PDF: build `values: [String: String]` and call `AcroFormFiller.fill` (its staleTarget maps to the service error). Output name: `"\(stem) (filled).\(ext)"` in `outputDir`; refuse to overwrite the input (reuse `outputEqualsInput`). Report: filled count, skipped = every non-confirmed blank (reason from status: "rejected by reviewer", "no matching field", "not confirmed") plus manual widgets (reason "manual widget type").

- [ ] **Step 11.1: Write failing tests** in `FillServiceTests.swift`: DOCX happy path end-to-end with a fixture docx (no model: pre-confirm blanks by editing the plan), AcroForm happy path, value-free report assertion (encode the report to JSON and assert it does not contain a filled value string), unmatched-and-rejected blanks skipped with reasons, output never overwrites input, stale DOCX target throws (modify the docx between plan and apply), extractProfile with one readable and one unreadable source returns a profile plus that source in `failedSources` (use a fake-completer seam if the facade exposes one for tests; otherwise test the import-failure collection through a deterministic-only path and leave model-path wiring to the live test), extractProfile with zero readable sources throws, and planFill on a `.txt` target throws `DocumentIOError.unsupportedFormat`.

- [ ] **Step 11.2: Run to verify failure.**

- [ ] **Step 11.3: Implement.**

- [ ] **Step 11.4: Run `swift test --filter FillServiceTests` then the FULL suite** (`swift test 2>&1 | tail -3`). Expected: PASS, suite green.

- [ ] **Step 11.5: Commit**

```bash
git add Sources/LDACore/Service/LDAService.swift Tests/LDACoreTests/FillServiceTests.swift
git -c commit.gpgsign=false commit -m "feat: extractProfile, planFill, applyFill facade operations"
```

---

### Task 12: FillModel (UI view-model)

**Files:**
- Create: `Sources/LDAUI/FillModel.swift`
- Test: `Tests/LDACoreTests/FillModelTests.swift`

**Read `ReviewModel.swift` fully first** and copy its conventions: `@MainActor final class`, `@Published` state, heavy work in detached Tasks publishing back to the main actor, caller-supplied timestamps at export seams, status enum.

**State machine:**

```swift
public enum FillStage: Equatable {
    case idle
    case importingSources
    case extracting          // model running over sources
    case profileReady        // profile editable; conflicts must clear to save
    case planning            // target imported, blanks being matched
    case reviewing           // blank-by-blank review
    case applying
    case done(FillReport)
    case failed(String)
}
```

**Published state:** `stage`, `profile: CompanyProfile?`, `profileDirty: Bool`, `blanks: [Blank]`, `selectedBlankID: UUID?`, `targetURL: URL?`, `manualWidgetNames: [String]`, `progress: Double`, `sourceWarnings: [String]` (display strings built from `ExtractProfileResult.failedSources`), plus `modelPath: String?` (same source as `ReviewModel.modelPath`).

**Intents (each unit-testable synchronously where possible):** `setProfile`, `updateField(id:value:)` (sets `userEdited`, marks dirty), `removeField(id:)`, `resolveConflict(key:keepFieldID:)` (removes the other fields of that key), `loadProfile(_ profile:)`, `acceptBlank(id:)` / `rejectBlank(id:)` / `acceptAllProposed()`, `repointBlank(id:fieldID:)` (sets proposedFieldID, proposedValue = field value, status proposed), `confirmBlank(id:)` semantics: accept moves `proposed` to `confirmed`; reject moves anything to `rejected`; keyboard flow mirrors the entity review loop (next/previous selection helpers `selectNextBlank()` / `selectPreviousBlank()`). Accepting a blank whose `proposedValue` is nil (ambiguous match awaiting a pick) is a NO-OP that signals the UI to open the field picker instead; `acceptAllProposed()` skips such blanks as well as unmatched and rejected ones.
Async intents wrapping the facade: `extractProfile(sources:)`, `planFill(target:)`, `applyFill(outputDir:)`; sync, injectable core seams so tests do not need the model: store the facade calls behind `var extractRunner`, `var planRunner`, `var applyRunner` closures (the pattern `ReviewModel` uses for its export/restore seams; reconcile with how it actually injects and mirror that).

- [ ] **Step 12.1: Write failing tests** covering: accept/reject/repoint transitions, `acceptAllProposed` skips unmatched and rejected, apply gating (applyFill only sees confirmed blanks; assert via injected fake runner capturing the plan), conflict resolution removes losers and clears `conflictedKeys`, profile edit marks dirty and sets `userEdited`.

- [ ] **Step 12.2: Run to verify failure.**

- [ ] **Step 12.3: Implement `FillModel.swift`.**

- [ ] **Step 12.4: Run `swift test --filter FillModelTests`.** Expected PASS.

- [ ] **Step 12.5: Commit**

```bash
git add Sources/LDAUI/FillModel.swift Tests/LDACoreTests/FillModelTests.swift
git -c commit.gpgsign=false commit -m "feat: FillModel view-model for profile building and fill review"
```

---

### Task 13: Fill mode UI (FillShell + RootShell)

**Files:**
- Create: `Sources/LDAUI/FillShell.swift`, `Sources/LDAUI/RootShell.swift`
- Modify: `Sources/LDAApp/LDAApp.swift`

**Read `AppShell.swift`, `DocumentPane.swift`, `EntitySidebar.swift`, `CounselTheme.swift`, and `LDAApp.swift` fully first.** Follow CounselTheme styling and the existing banner/announce patterns. Known platform gotchas already learned in this repo (respect them): use `NSOpenPanel`/`NSSavePanel`, never two `.fileImporter`s on one view; programmatic Settings opening needs `@Environment(\.openSettings)`.

**RootShell:** a top-level mode switcher (segmented `Picker` in the toolbar or a leading sidebar toggle, match the existing chrome) hosting the existing `AppShell` ("Anonymize") and the new `FillShell` ("Fill"). `LDAApp.swift` swaps its root view to `RootShell`. Both child views keep their own models; switching modes must not tear down in-progress work (hold both views alive, for example with a `ZStack` plus opacity or a `TabView` with `.tabViewStyle(.automatic)`; pick whichever pattern the existing code base tolerates best and keep models as `@StateObject` on RootShell).

**FillShell, two stages of chrome (driven by `FillStage`):**
1. Profile builder: toolbar buttons Add Sources (NSOpenPanel, multi-select), Extract (disabled without model path; reuse the model-path plumbing AppShell uses), Save Profile / Load Profile (NSSavePanel / NSOpenPanel, `.ldaprofile`, passphrase sheet matching the export passphrase sheet pattern in AppShell). Body: table of fields (columns: key displayName, value as editable TextField, source document, verified or unverified badge, confidence) with a conflict banner listing `conflictedKeys` and per-key resolve controls; an `incomplete` warning banner mirroring the existing warning banner style.
2. Fill review: Open Target button (NSOpenPanel: docx and pdf only; txt is not a fill target per the spec non-goals); document pane reusing the text-highlighting approach of `DocumentPane` for DOCX targets (highlight blank spans, selected blank emphasized; for PDF targets show the field list only in V1); sidebar listing blanks (label or context preview, proposed value, status icon) with keyboard-first bindings copied from the entity review loop (same keys: accept, reject, next, previous; read the keyboard handling in `EntitySidebar`/`AppShell` from commit 6aca195 and mirror it); a field picker popover for `repointBlank`, PRE-OPENED when a blank is ambiguous (proposed with nil proposedFieldID, per spec section 6); when the planner proposed a format-adapted value, show it BESIDE the verbatim profile value, never instead of it; Apply button (NSSavePanel for the output directory) that runs `applyFill` and then shows the value-free report (filled count, skipped list, manual widgets) in the existing alert/banner style. In the profile builder stage, the Save Profile button stays DISABLED while `conflictedKeys` is non-empty and a banner names the keys needing resolution (spec sections 4 and 9); the extract step surfaces `failedSources` in the same warning banner style.

- [ ] **Step 13.1: Implement RootShell + minimal FillShell skeleton; `swift build` must stay green.**
- [ ] **Step 13.2: Implement the profile builder stage.** Manual check: `swift run LDAApp`, switch to Fill, add a source, extract with a real model if available (otherwise verify the disabled state and error surfaces).
- [ ] **Step 13.3: Implement the fill review stage.** Manual check with a fixture docx containing `[Company Name]` and a saved profile.
- [ ] **Step 13.4: Run the FULL test suite** (`swift test 2>&1 | tail -3`): green.
- [ ] **Step 13.5: Commit**

```bash
git add Sources/LDAUI/FillShell.swift Sources/LDAUI/RootShell.swift Sources/LDAApp/LDAApp.swift
git -c commit.gpgsign=false commit -m "feat: Counsel Fill mode UI (profile builder and fill review)"
```

---

### Task 14: CLI subcommands

**Files:**
- Modify: `Sources/LDACLI/CLI.swift` (or a sibling file in `Sources/LDACLI/` if CLI.swift is near the 800-line bound; check first)
- Test: extend `Tests/LDACoreTests/CLITests.swift`

**Pattern:** mirror `Anonymize` exactly: `ParsableCommand` struct, options, `run()` calling injectable static helpers, summary printed via `CLIJSON.encode`.

**Commands:**

```text
lda extract-profile --label "Acme" --out matter.ldaprofile [--passphrase ...] --model /path/model.gguf cert.pdf articles.pdf
    Runs extractProfile, saves via ProfileStore, prints a SAFE summary JSON:
    {fieldCount, keys: [rawKey], conflictedKeys, incomplete, failedSources,
    profilePath}. Field VALUES are never printed by extract-profile.

lda fill --profile matter.ldaprofile [--passphrase ...] --input draft.docx [--model /path/model.gguf] --plan
    Loads the profile, runs planFill, prints the PLAN JSON to stdout
    (blank label, location description, status, proposed field rawKey,
    proposed value, and for ambiguous blanks a candidates array of the
    plausible field rawKeys). Values appear on stdout ONLY here, for human
    review; nothing is persisted.

lda fill --profile matter.ldaprofile [--passphrase ...] --input draft.docx [--model /path/model.gguf] --apply --output-dir out/
    Re-runs planFill deterministically (greedy decoding makes the plan
    reproducible), promotes every .proposed blank with a value to .confirmed,
    runs applyFill, prints the value-free FillReport JSON.
```

`--plan` and `--apply` are mutually exclusive; exactly one is required (validate in `validate()`; ArgumentParser supports it).

- [ ] **Step 14.1: Write failing tests** in the established CLITests style (drive the injectable helpers, not the process): extract-profile summary contains keys but no values; fill --plan output contains proposed values; fill --apply writes the filled file and prints a value-free report; mutual exclusion validation throws.
- [ ] **Step 14.2: Run to verify failure.**
- [ ] **Step 14.3: Implement** (`ExtractProfile`, `Fill` subcommands added to `LDARoot.configuration.subcommands`, summary structs, `LDACLI.runExtractProfile` / `runFillPlan` / `runFillApply` helpers). Note `ExtractProfileResult.failedSources` is a labeled-tuple array (Sendable, not Codable); the CLI summary needs its own small Codable struct (for example `FailedSourceJSON {name, reason}`); do not try to encode the facade type directly.
- [ ] **Step 14.4: Run `swift test --filter CLITests`.** Expected PASS.
- [ ] **Step 14.5: Commit**

```bash
git add Sources/LDACLI/ Tests/LDACoreTests/CLITests.swift
git -c commit.gpgsign=false commit -m "feat: extract-profile and fill CLI subcommands"
```

---

### Task 15: MCP tools

**Files:**
- Modify: `Sources/LDAMCP/MCPServer.swift`
- Test: extend `Tests/LDACoreTests/MCPTests.swift`

Mirror the CLI semantics as two tools in `toolDescriptors` plus `handleToolsCall` cases:
- `extract_profile` (params: `sources: [string]`, `label: string`, `out: string`, `model: string`, optional `passphrase`): returns the same safe summary as the CLI (no values).
- `fill` (params: `profile: string`, `input: string`, `mode: "plan" | "apply"`, optional `model`, optional `passphrase`, `output_dir` required for apply): plan returns the plan JSON (values included, same review rationale as the CLI), apply returns the value-free report.

- [ ] **Step 15.1: Write failing tests** in MCPTests style (tools/list includes the new descriptors; tools/call routes and returns expected JSON shapes; errors map to MCP errors).
- [ ] **Step 15.2: Run to verify failure.**
- [ ] **Step 15.3: Implement.**
- [ ] **Step 15.4: Run `swift test --filter MCPTests`.** Expected PASS.
- [ ] **Step 15.5: Commit**

```bash
git add Sources/LDAMCP/MCPServer.swift Tests/LDACoreTests/MCPTests.swift
git -c commit.gpgsign=false commit -m "feat: extract_profile and fill MCP tools"
```

---

### Task 16: Live model test, docs, final sweep, merge

**Files:**
- Create: `Tests/LDACoreTests/FillLiveModelTests.swift`
- Modify: `README.md` (repo root), `macos/LDACore/README.md`

- [ ] **Step 16.1: Live test** (gated like the existing live tests: `XCTSkip` unless `LDA_MODEL_PATH` is set; read one to copy the guard): synthesize a small certificate-like text file, run `LDAService.extractProfile`, assert at least `companyName` extracted and grounded; then plan and apply against a fixture docx containing `[Company Name]` and assert the filled output contains the extracted name.

Run: `LDA_MODEL_PATH=/path/to/model.gguf swift test --filter FillLiveModelTests` when a model is available on this machine; otherwise verify the skip:
Run: `swift test --filter FillLiveModelTests 2>&1 | tail -3`
Expected: skipped, not failed.

- [ ] **Step 16.2: Docs.** `macos/LDACore/README.md`: add a "Fill from profile" section (the three CLI commands, the `.ldaprofile` format note, the review-first posture, V1 limits). Repo `README.md`: one short paragraph in the feature list pointing at the macOS app section. No em-dashes.

- [ ] **Step 16.3: Full suite and build sweep**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3
```

Expected: build clean, all tests green (331 baseline plus all new).

- [ ] **Step 16.4: Commit docs, then merge to `feat/lda-macos-core`** (solo project, no PR ceremony).

`feat/lda-macos-core` is checked out at the PRIMARY repo checkout under iCloud (`git worktree list` confirms), so `git checkout feat/lda-macos-core` inside the fill worktree would be REFUSED by git. Merge in two moves instead: first sync the feature branch with any upstream movement and test it in the fill worktree, then fast-forward the upstream branch at the primary checkout (merging there is fine; only BUILDING under iCloud is forbidden). The `--ff-only` guarantees the tree that lands on `feat/lda-macos-core` is byte-identical to the one just tested.

```bash
# All paths are repo-root relative; run the add/commit from the worktree root.
cd ~/Developer/lda-worktrees/fill
git add README.md macos/LDACore/README.md macos/LDACore/Tests/LDACoreTests/FillLiveModelTests.swift
git -c commit.gpgsign=false commit -m "docs: fill-from-profile docs and live model test"

# 1. Bring any upstream movement INTO the feature branch and re-test here.
git merge feat/lda-macos-core -m "merge: sync upstream feat/lda-macos-core"
cd macos/LDACore && swift test 2>&1 | tail -3

# 2. Fast-forward the upstream branch at its own checkout. Fails loudly
#    instead of creating an untested merge if upstream moved meanwhile.
cd "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer"
git merge --ff-only feat/fill-from-profile
```

Expected: suite green in the fill worktree, then a clean fast-forward; `feat/lda-macos-core` now points at the tested commit. If `--ff-only` fails (upstream moved between the two steps), repeat step 1 and retry. If the user wants it on `main` too, that is a separate decision to surface, not assume.

---

## Execution notes

- Tasks 1 through 10 are core-only and parallel-friendly in principle, but execute them in order: each later task consumes earlier types.
- Tasks 12 and 13 (UI) depend on 11. Tasks 14 and 15 depend on 11 and are cuttable per the spec.
- If any reconciliation note reveals the plan's snippet does not compile against real code, fix the call site to match the codebase, keep the test's behavioral contract, and note the deviation in the commit message body.
- Never weaken an existing test to make a new feature pass. If an existing test breaks, the change is wrong; stop and re-read.
