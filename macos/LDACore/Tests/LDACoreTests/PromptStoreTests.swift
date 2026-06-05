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
}
