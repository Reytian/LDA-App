//
//  PseudonymOverrideUITests.swift
//  LDACoreTests
//
//  The session plumbing for editable pseudonym replacements (F5): the edit
//  API validates through PseudonymOverrideValidator and surfaces the typed
//  rejection, accepted overrides flow into the hand-to-AI build, rebuilds are
//  idempotent, the identity persists under a matter across sessions, and the
//  affordance is gated to the pseudonym style.
//
//  Deterministic-only sessions; hermetic temp-rooted stores with passphrase
//  protection (no Keychain).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class PseudonymOverrideUITests: XCTestCase {

    private static let createdAt = "2026-08-31T00:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PseudonymOverrideUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func makeSession() -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        let recordRoot = workDir.appendingPathComponent("records")
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        let matterRoot = workDir.appendingPathComponent("matters")
        session.matterStore = { try MatterMetadataStore(rootDirectory: matterRoot) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.outputStyleProvider = { .pseudonym }
        return session
    }

    /// One scanned email document, the smallest deterministic pseudonym case.
    private func makeSessionWithScannedEmail() async throws -> SessionModel {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        return session
    }

    // MARK: - Gate

    func testEditingIsAvailableOnlyForThePseudonymStyle() {
        XCTAssertTrue(PseudonymEditingPresentation.isEditingAvailable(style: .pseudonym))
        XCTAssertFalse(PseudonymEditingPresentation.isEditingAvailable(style: .token))
        XCTAssertFalse(PseudonymEditingPresentation.isEditingAvailable(style: .asterisk))
        XCTAssertFalse(PseudonymEditingPresentation.footnote.isEmpty)
    }

    func testRowShowsTheOverrideOverTheAssignedReplacement() {
        XCTAssertEqual(
            PseudonymEditingPresentation.currentReplacement(
                override: "Buyer A",
                assignedToken: "contact1@example.com"
            ),
            "Buyer A"
        )
        XCTAssertEqual(
            PseudonymEditingPresentation.currentReplacement(
                override: nil,
                assignedToken: "contact1@example.com"
            ),
            "contact1@example.com"
        )
        XCTAssertNil(
            PseudonymEditingPresentation.currentReplacement(override: nil, assignedToken: nil)
        )
    }

    // MARK: - Validation surfacing

    func testRejectedOverrideSurfacesTheTypedReasonAndChangesNothing() async throws {
        let session = try await makeSessionWithScannedEmail()

        // The replacement occurs naturally in the corpus.
        XCTAssertThrowsError(
            try session.setPseudonymOverride(surface: "john@acme.com", replacement: "please")
        ) { error in
            guard case PseudonymOverrideError.occursNaturallyInCorpus(let surface, let replacement) = error else {
                return XCTFail("expected occursNaturallyInCorpus, got \(error)")
            }
            XCTAssertEqual(surface, "john@acme.com")
            XCTAssertEqual(replacement, "please")
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(session.pseudonymOverrides.isEmpty, "a rejected edit must change nothing")

        // Braces would collide with the token grammar.
        XCTAssertThrowsError(
            try session.setPseudonymOverride(surface: "john@acme.com", replacement: "{EMAIL_9}")
        ) { error in
            guard case PseudonymOverrideError.containsBraces = error else {
                return XCTFail("expected containsBraces, got \(error)")
            }
        }
        XCTAssertTrue(session.pseudonymOverrides.isEmpty)
    }

    func testOverrideUnderTokenStyleIsRejectedAtEditTime() async throws {
        let session = try await makeSessionWithScannedEmail()
        session.outputStyleProvider = { .token }

        XCTAssertThrowsError(
            try session.setPseudonymOverride(surface: "john@acme.com", replacement: "contact@buyer.example")
        ) { error in
            guard case PseudonymOverrideError.styleNotPseudonym(let style) = error else {
                return XCTFail("expected styleNotPseudonym, got \(error)")
            }
            XCTAssertEqual(style, .token)
        }
    }

    // MARK: - Build integration

    func testAcceptedOverrideFlowsIntoTheBuiltOutputAndChips() async throws {
        let session = try await makeSessionWithScannedEmail()
        try session.setPseudonymOverride(
            surface: "john@acme.com",
            replacement: "contact@buyer.example"
        )

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertFalse(result.combined.contains("john@acme.com"))
        XCTAssertTrue(result.combined.contains("contact@buyer.example"))
        XCTAssertEqual(
            session.entries[0].model.entities.first?.token,
            "contact@buyer.example",
            "the sealed chip must show the forced replacement"
        )

        // The round trip restores the original through the unchanged Restorer.
        let restored = try XCTUnwrap(session.restorePasted(result.combined))
        XCTAssertTrue(restored.text.contains("john@acme.com"))
    }

    func testRebuildWithTheSameOverrideIsIdempotent() async throws {
        let session = try await makeSessionWithScannedEmail()
        try session.setPseudonymOverride(
            surface: "john@acme.com",
            replacement: "contact@buyer.example"
        )

        let first = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        let second = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertEqual(first.combined, second.combined)
        XCTAssertEqual(session.sessionMapping?.entries.count, 1)
    }

    func testClearingAnOverrideReturnsToTheAutomaticPseudonym() async throws {
        let session = try await makeSessionWithScannedEmail()
        try session.setPseudonymOverride(
            surface: "john@acme.com",
            replacement: "contact@buyer.example"
        )
        try session.setPseudonymOverride(surface: "john@acme.com", replacement: nil)
        XCTAssertTrue(session.pseudonymOverrides.isEmpty)

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertTrue(result.combined.contains("contact1@example.com"))
        XCTAssertFalse(result.combined.contains("contact@buyer.example"))
    }

    func testStyleSwitchIgnoresStoredOverridesInsteadOfBreakingTheBuild() async throws {
        let session = try await makeSessionWithScannedEmail()
        try session.setPseudonymOverride(
            surface: "john@acme.com",
            replacement: "contact@buyer.example"
        )
        // The user changes the output style in Settings after editing.
        session.outputStyleProvider = { .token }

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertTrue(result.combined.contains("{EMAIL_1}"))
        XCTAssertFalse(result.combined.contains("contact@buyer.example"))
    }

    // MARK: - Persistence across the round trip and sessions

    func testOverriddenIdentityPersistsUnderTheMatterAcrossSessions() async throws {
        let session = try await makeSessionWithScannedEmail()
        XCTAssertTrue(try session.selectMatter("Matter A", discardingDocuments: true))
        let doc = try write("b.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        try session.setPseudonymOverride(
            surface: "john@acme.com",
            replacement: "contact@buyer.example"
        )
        XCTAssertNotNil(try session.buildHandToAI(createdAtISO8601: Self.createdAt))

        // A later session under the same matter reuses the forced identity
        // through the client mapping seed, with no override in hand.
        let later = makeSession()
        XCTAssertTrue(try later.selectMatter("Matter A", discardingDocuments: true))
        let doc2 = try write("c.txt", "Reply to john@acme.com today.")
        await later.addDocuments([doc2])
        await later.anonymizeAll()
        let result = try XCTUnwrap(later.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertTrue(result.combined.contains("contact@buyer.example"))
        XCTAssertFalse(result.combined.contains("john@acme.com"))
    }

    func testMatterSwitchDropsSessionOverrides() async throws {
        let session = try await makeSessionWithScannedEmail()
        try session.setPseudonymOverride(
            surface: "john@acme.com",
            replacement: "contact@buyer.example"
        )
        XCTAssertTrue(try session.selectMatter("Matter B", discardingDocuments: true))
        XCTAssertTrue(
            session.pseudonymOverrides.isEmpty,
            "overrides reference the outgoing session's surfaces"
        )
    }
}
