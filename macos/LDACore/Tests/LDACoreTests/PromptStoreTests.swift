//
//  PromptStoreTests.swift
//  LDACoreTests
//
//  Tests for PromptStore: editing then reset restores the exact ported default,
//  validate flags a body that drops the JSON instruction or placeholders, and
//  the Codable snapshot round-trips.
//
//  House rules: English only, no em-dash and no en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class PromptStoreTests: XCTestCase {

    // MARK: Defaults seeding

    func testInitSeedsCurrentBodiesFromDefaults() {
        let store = PromptStore()

        XCTAssertEqual(store.currentPass1, PromptStore.defaultPass1)
        XCTAssertEqual(store.currentPass2, PromptStore.defaultPass2)
    }

    func testDefaultsMatchPortedPythonContract() {
        // Spot-check that the ported bodies carry the load-bearing tokens so a
        // silent edit to the source constants does not pass unnoticed.
        XCTAssertTrue(PromptStore.defaultPass1.contains("{key_sections_text}"))
        XCTAssertTrue(PromptStore.defaultPass1.contains("JSON 格式返回"))
        XCTAssertTrue(PromptStore.defaultPass1.contains("不要加 ```json"))

        XCTAssertTrue(PromptStore.defaultPass2.contains("{entity_aliases_context}"))
        XCTAssertTrue(PromptStore.defaultPass2.contains("{document_segment}"))
        XCTAssertTrue(PromptStore.defaultPass2.contains("JSON 数组格式返回"))
        XCTAssertTrue(PromptStore.defaultPass2.contains("不要加 ```json"))
    }

    // MARK: Edit then reset

    func testResetPass1RestoresExactDefault() {
        let store = PromptStore()
        store.currentPass1 = "edited pass 1 body"
        XCTAssertNotEqual(store.currentPass1, PromptStore.defaultPass1)

        store.reset(.pass1)

        XCTAssertEqual(store.currentPass1, PromptStore.defaultPass1)
    }

    func testResetPass2RestoresExactDefault() {
        let store = PromptStore()
        store.currentPass2 = "edited pass 2 body"
        XCTAssertNotEqual(store.currentPass2, PromptStore.defaultPass2)

        store.reset(.pass2)

        XCTAssertEqual(store.currentPass2, PromptStore.defaultPass2)
    }

    func testResetPass1DoesNotTouchPass2() {
        let store = PromptStore()
        store.currentPass1 = "edited pass 1"
        store.currentPass2 = "edited pass 2"

        store.reset(.pass1)

        XCTAssertEqual(store.currentPass1, PromptStore.defaultPass1)
        XCTAssertEqual(store.currentPass2, "edited pass 2")
    }

    func testResetAllRestoresBothDefaults() {
        let store = PromptStore()
        store.currentPass1 = "edited pass 1"
        store.currentPass2 = "edited pass 2"

        store.resetAll()

        XCTAssertEqual(store.currentPass1, PromptStore.defaultPass1)
        XCTAssertEqual(store.currentPass2, PromptStore.defaultPass2)
    }

    func testEditThenResetIsByteIdenticalToDefault() {
        let store = PromptStore()
        let original = store.currentPass1

        store.currentPass1 = original + " trailing edit"
        store.reset(.pass1)

        // Exact equality, not a normalized or trimmed compare.
        XCTAssertTrue(store.currentPass1 == PromptStore.defaultPass1)
        XCTAssertEqual(store.currentPass1.count, PromptStore.defaultPass1.count)
    }

    // MARK: Validation

    func testValidateAcceptsDefaultPass1() {
        XCTAssertEqual(PromptStore.validate(PromptStore.defaultPass1), [])
    }

    func testValidateAcceptsDefaultPass2() {
        XCTAssertEqual(PromptStore.validate(PromptStore.defaultPass2), [])
    }

    func testValidateFlagsBodyMissingJSONInstruction() {
        // Start from the default, then strip the JSON-output instruction phrase.
        let stripped = PromptStore.defaultPass1
            .replacingOccurrences(of: "JSON 格式返回", with: "纯文本返回")

        let warnings = PromptStore.validate(stripped)

        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(
            warnings.contains { $0.contains("JSON-output instruction") },
            "Expected a warning about the missing JSON-output instruction, got: \(warnings)"
        )
    }

    func testValidateFlagsBodyMissingNoFenceDirective() {
        let stripped = PromptStore.defaultPass2
            .replacingOccurrences(of: "不要加 ```json", with: "可以")

        let warnings = PromptStore.validate(stripped)

        XCTAssertTrue(
            warnings.contains { $0.contains("no-code-fence") },
            "Expected a warning about the missing no-code-fence directive, got: \(warnings)"
        )
    }

    func testValidateFlagsPass1BodyMissingPlaceholder() {
        let stripped = PromptStore.defaultPass1
            .replacingOccurrences(of: "{key_sections_text}", with: "")

        let warnings = PromptStore.validate(stripped)

        XCTAssertTrue(
            warnings.contains { $0.contains("no slot to inject") },
            "Expected a warning about the missing substitution placeholder, got: \(warnings)"
        )
    }

    func testValidateFlagsPass2BodyMissingOnePlaceholder() {
        // Remove just one of the two Pass-2 placeholders.
        let stripped = PromptStore.defaultPass2
            .replacingOccurrences(of: "{document_segment}", with: "")

        let warnings = PromptStore.validate(stripped)

        XCTAssertTrue(
            warnings.contains { $0.contains("Pass-2 placeholder") },
            "Expected a warning about a missing Pass-2 placeholder, got: \(warnings)"
        )
        XCTAssertTrue(
            warnings.contains { $0.contains("{document_segment}") },
            "Expected the warning to name the missing placeholder, got: \(warnings)"
        )
    }

    func testValidateReturnsMultipleWarningsForFullyStrippedBody() {
        let warnings = PromptStore.validate("just some prose with no anchors at all")

        // No JSON instruction, no no-fence directive, no placeholder.
        XCTAssertGreaterThanOrEqual(warnings.count, 3)
    }

    // MARK: Codable snapshot round-trip

    func testSnapshotReflectsCurrentBodies() {
        let store = PromptStore()
        store.currentPass1 = "p1"
        store.currentPass2 = "p2"

        let snap = store.snapshot

        XCTAssertEqual(snap.pass1, "p1")
        XCTAssertEqual(snap.pass2, "p2")
    }

    func testSnapshotRoundTripsThroughCodable() throws {
        let store = PromptStore()
        store.currentPass1 = "edited pass 1 with unicode 甲方 and braces {x}"
        store.currentPass2 = "edited pass 2 with fence ```json and newline\nsecond line"

        let original = store.snapshot

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PromptSnapshot.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.pass1, store.currentPass1)
        XCTAssertEqual(decoded.pass2, store.currentPass2)
    }

    func testDefaultSnapshotRoundTripsExactly() throws {
        let store = PromptStore()

        let encoded = try JSONEncoder().encode(store.snapshot)
        let decoded = try JSONDecoder().decode(PromptSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.pass1, PromptStore.defaultPass1)
        XCTAssertEqual(decoded.pass2, PromptStore.defaultPass2)
    }

    // MARK: Snapshot construction and application

    func testInitFromSnapshotSeedsBodies() {
        let snap = PromptSnapshot(pass1: "a", pass2: "b")

        let store = PromptStore(snapshot: snap)

        XCTAssertEqual(store.currentPass1, "a")
        XCTAssertEqual(store.currentPass2, "b")
    }

    func testApplySnapshotReplacesBodies() {
        let store = PromptStore()
        store.apply(PromptSnapshot(pass1: "x", pass2: "y"))

        XCTAssertEqual(store.currentPass1, "x")
        XCTAssertEqual(store.currentPass2, "y")
    }

    func testApplyThenResetAllReturnsToDefaults() {
        let store = PromptStore()
        store.apply(PromptSnapshot(pass1: "x", pass2: "y"))

        store.resetAll()

        XCTAssertEqual(store.currentPass1, PromptStore.defaultPass1)
        XCTAssertEqual(store.currentPass2, PromptStore.defaultPass2)
    }

    // MARK: Profile prompt

    func testProfilePromptDefaultsCarryJSONContractAndKeys() {
        let store = PromptStore()
        // The template (currentProfileSystem / currentProfileTemplate) carries
        // the JSON contract phrase but NOT the raw key names (those live in the
        // {allowed_keys} slot). Re-target key assertions at the rendered output.
        XCTAssertTrue(store.currentProfileSystem.contains("JSON"))
        // The template must carry the literal slot so rendering can substitute it.
        XCTAssertTrue(
            store.currentProfileSystem.contains("{allowed_keys}"),
            "currentProfileSystem (template) must carry the {allowed_keys} slot"
        )
        // The four key names appear only in the rendered output for .company.
        let rendered = store.profileSystem(for: .company)
        for key in ["companyName", "companyNumber", "incorporationDate", "registeredOffice"] {
            XCTAssertTrue(rendered.contains(key), "rendered company system must contain '\(key)'")
        }
        let user = store.profileUser(documentName: "cert.pdf", chunk: "TEXT HERE")
        XCTAssertTrue(user.contains("TEXT HERE"))
        XCTAssertTrue(user.contains("cert.pdf"))
    }

    // MARK: BlankMatch prompt

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

    // MARK: Reset for new kinds

    func testResetRestoresProfileAndBlankMatchDefaults() {
        let store = PromptStore()
        store.currentProfileSystem = "edited"
        store.currentBlankMatchSystem = "edited"
        store.reset(.profile)
        store.reset(.blankMatch)
        XCTAssertEqual(store.currentProfileSystem, PromptStore.defaultProfileSystem)
        XCTAssertEqual(store.currentBlankMatchSystem, PromptStore.defaultBlankMatchSystem)
    }

    func testResetAllRestoresProfileAndBlankMatchDefaults() {
        let store = PromptStore()
        store.currentProfileSystem = "edited profile"
        store.currentBlankMatchSystem = "edited blankMatch"

        store.resetAll()

        XCTAssertEqual(store.currentProfileSystem, PromptStore.defaultProfileSystem)
        XCTAssertEqual(store.currentBlankMatchSystem, PromptStore.defaultBlankMatchSystem)
    }

    // MARK: Snapshot round-trip for new kinds
    //
    // Extraction is NOT stored in PromptSnapshot (the snapshot carries only pass1
    // and pass2, and init(snapshot:) seeds extraction to its default). Profile and
    // blankMatch follow the same pattern: they are NOT in PromptSnapshot. The tests
    // below verify that a legacy snapshot (no profile/blankMatch fields) decodes
    // successfully and that the store is seeded to its defaults in that case.

    func testLegacySnapshotDecodesWithoutProfileOrBlankMatchFields() throws {
        // A snapshot written before profile/blankMatch existed has only pass1/pass2.
        let legacyJSON = """
        {"pass1":"legacy-p1","pass2":"legacy-p2"}
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(PromptSnapshot.self, from: legacyJSON)
        let store = PromptStore(snapshot: snap)

        // The legacy bodies are restored from the snapshot.
        XCTAssertEqual(store.currentPass1, "legacy-p1")
        XCTAssertEqual(store.currentPass2, "legacy-p2")
        // The new prompts fall back to their defaults.
        XCTAssertEqual(store.currentProfileSystem, PromptStore.defaultProfileSystem)
        XCTAssertEqual(store.currentBlankMatchSystem, PromptStore.defaultBlankMatchSystem)
    }

    // MARK: - Kind-aware profileSystem(for:) tests (Task 4)

    func testProfileSystemForIndividualContainsPersonKeys() {
        let store = PromptStore()
        let rendered = store.profileSystem(for: .individual)
        XCTAssertTrue(rendered.contains("passportNumber"), "individual must contain passportNumber")
        XCTAssertTrue(rendered.contains("dateOfBirth"), "individual must contain dateOfBirth")
        XCTAssertFalse(
            rendered.contains("authorizedCapital"),
            "individual must NOT contain authorizedCapital"
        )
    }

    func testProfileSystemForCompanyContainsCompanyKeys() {
        let store = PromptStore()
        let rendered = store.profileSystem(for: .company)
        XCTAssertTrue(rendered.contains("companyName"), "company must contain companyName")
        XCTAssertTrue(rendered.contains("email"), "company must contain email")
        XCTAssertFalse(
            rendered.contains("passportNumber"),
            "company must NOT contain passportNumber"
        )
    }

    func testProfileSystemForGeneralContainsBothKeyGroups() {
        let store = PromptStore()
        let rendered = store.profileSystem(for: .general)
        XCTAssertTrue(rendered.contains("companyName"), "general must contain companyName")
        XCTAssertTrue(rendered.contains("passportNumber"), "general must contain passportNumber")
    }

    func testDefaultProfileTemplateCarriesAllowedKeysSlot() {
        // The raw template must carry the literal slot so it is visible to a host
        // that needs to know the contract before rendering.
        XCTAssertTrue(
            PromptStore.defaultProfileTemplate.contains("{allowed_keys}"),
            "defaultProfileTemplate must contain the literal {allowed_keys} slot"
        )
    }

    func testValidateProfileTemplateReturnsNoWarningsWhenIntact() {
        let warnings = PromptStore.validateProfileTemplate(PromptStore.defaultProfileTemplate)
        XCTAssertEqual(warnings, [], "intact template must produce no warnings; got \(warnings)")
    }

    func testValidateProfileTemplateWarnsWhenAllowedKeysSlotDropped() {
        let edited = PromptStore.defaultProfileTemplate
            .replacingOccurrences(of: "{allowed_keys}", with: "companyName, companyNumber")
        let warnings = PromptStore.validateProfileTemplate(edited)
        XCTAssertFalse(
            warnings.isEmpty,
            "validateProfileTemplate must warn when {allowed_keys} slot is dropped"
        )
    }

    func testValidateProfileTemplateWarnsWhenRawJSONContractDropped() {
        let edited = PromptStore.defaultProfileTemplate
            .replacingOccurrences(of: "RAW JSON ONLY", with: "some output")
        let warnings = PromptStore.validateProfileTemplate(edited)
        XCTAssertFalse(
            warnings.isEmpty,
            "validateProfileTemplate must warn when the raw-JSON contract sentence is dropped"
        )
    }

    func testProfileSystemBodyContainsIdentityDocumentOpening() {
        let store = PromptStore()
        // The generalized opening should mention identity documents so both
        // company and individual docs are covered.
        let rendered = store.profileSystem(for: .individual)
        XCTAssertTrue(
            rendered.lowercased().contains("identity"),
            "rendered profile system must mention 'identity' in its opening"
        )
    }

    // MARK: Ripple: testProfilePromptDefaultsCarryJSONContractAndKeys
    //
    // After templating, currentProfileSystem holds the raw template (with the
    // {allowed_keys} slot). The four key-name assertions must therefore target the
    // rendered output of profileSystem(for: .company), which has the slot substituted.

    func testProfilePromptDefaultsCarryJSONContractAndKeysViaRendered() {
        let store = PromptStore()
        // The template must still carry the JSON contract phrase.
        XCTAssertTrue(
            store.currentProfileTemplate.contains("JSON"),
            "currentProfileTemplate must contain 'JSON'"
        )
        // The four key names appear only after rendering.
        let rendered = store.profileSystem(for: .company)
        for key in ["companyName", "companyNumber", "incorporationDate", "registeredOffice"] {
            XCTAssertTrue(rendered.contains(key), "rendered company system must contain '\(key)'")
        }
        // The user builder is unchanged.
        let user = store.profileUser(documentName: "cert.pdf", chunk: "TEXT HERE")
        XCTAssertTrue(user.contains("TEXT HERE"))
        XCTAssertTrue(user.contains("cert.pdf"))
    }
}
