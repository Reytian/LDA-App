//
//  UIStyleTests.swift
//  LDACoreTests
//
//  Tests for the GUI side of the output styles: the persisted AISettings
//  value, the export path (performExport), the Safe Preview, the session
//  Copy for AI + paste-restore round trip in pseudonym style, including the
//  simulated AI rewrite that breaks brace tokens, and the asterisk mask that
//  fits two people and is therefore refused, reported to the user, and
//  recorded on the session's restore event.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAUI
@testable import LDACore

// MARK: - Settings persistence

final class AISettingsOutputStyleTests: XCTestCase {

    func testDefaultOutputStyleIsToken() throws {
        let suiteName = "AISettingsOutputStyle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AISettings.outputStyle(defaults: defaults), .token)
    }

    func testOutputStyleRoundTripsThroughDefaults() throws {
        let suiteName = "AISettingsOutputStyle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for style in SubstitutionStyle.allCases {
            AISettings.setOutputStyle(style, defaults: defaults)
            XCTAssertEqual(AISettings.outputStyle(defaults: defaults), style)
        }
    }

    func testUnknownStoredValueFallsBackToToken() throws {
        let suiteName = "AISettingsOutputStyle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("emoji", forKey: AISettings.outputStyleKey)
        XCTAssertEqual(AISettings.outputStyle(defaults: defaults), .token)
    }
}

// MARK: - Export and preview

final class ReviewModelStyleTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func emailSpan(in text: String) -> Span {
        let ns = text as NSString
        let range = ns.range(of: "jane.doe@example.com")
        precondition(range.location != NSNotFound)
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: .email,
            text: "jane.doe@example.com",
            source: .deterministic,
            confidence: 1.0,
            priority: 100
        )
    }

    func testPerformExportHonorsPseudonymStyle() throws {
        let text = "Mail jane.doe@example.com today."
        let result = try ReviewModel.performExport(
            text: text,
            acceptedSpans: [emailSpan(in: text)],
            source: nil,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: workDir,
            passphrase: "ui-style-pw",
            createdAtISO8601: "2026-08-30T00:00:00Z",
            style: .pseudonym
        )

        let redacted = try String(contentsOf: result.export.redactedURL, encoding: .utf8)
        XCTAssertEqual(redacted, "Mail contact1@example.com today.")
        // Sealed chips show the pseudonym for the surface.
        XCTAssertEqual(result.tokenBySurface["jane.doe@example.com"], "contact1@example.com")

        let mapping = try MappingStore.load(
            from: result.export.mappingURL,
            protection: .passphrase("ui-style-pw")
        )
        XCTAssertEqual(mapping.style, .pseudonym)
    }

    func testRedactedPreviewFollowsStyle() {
        let text = "Mail jane.doe@example.com today."
        let entities = [ReviewEntity(span: emailSpan(in: text), accepted: true)]

        XCTAssertEqual(
            ReviewModel.redactedPreviewText(text: text, entities: entities, style: .token),
            "Mail {EMAIL_1} today."
        )
        XCTAssertEqual(
            ReviewModel.redactedPreviewText(text: text, entities: entities, style: .pseudonym),
            "Mail contact1@example.com today."
        )
        XCTAssertEqual(
            ReviewModel.redactedPreviewText(text: text, entities: entities, style: .asterisk),
            "Mail jane************.com today."
        )
    }
}

// MARK: - Session Copy for AI in pseudonym style

@MainActor
final class SessionModelStyleTests: XCTestCase {

    private var workDir: URL!
    private static let createdAt = "2026-08-30T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionModelStyleTests-\(UUID().uuidString)", isDirectory: true)
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
        return session
    }

    func testHandToAIPseudonymSurvivesAIRewriteAndRestores() async throws {
        let session = makeSession()
        session.outputStyleProvider = { .pseudonym }

        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertFalse(result.combined.contains("john@acme.com"))
        XCTAssertTrue(result.combined.contains("contact1@example.com"))
        XCTAssertFalse(result.combined.contains("{EMAIL_1}"))
        XCTAssertEqual(session.sessionMapping?.style, .pseudonym)

        // Sealed chips show the pseudonym.
        XCTAssertEqual(session.entries[0].model.entities.first?.token, "contact1@example.com")

        // The simulated AI rewriter (which mangles every brace token) finds
        // nothing to mangle, and the pasted answer restores.
        let afterAI = AIRewriteSimulator.rewriteTokens(in: result.combined)
        XCTAssertEqual(afterAI, result.combined)

        let restored = try XCTUnwrap(session.restorePasted(afterAI))
        XCTAssertTrue(restored.text.contains("john@acme.com"))
        XCTAssertEqual(restored.restoredCount, 1)
    }

    /// End to end for the GUI's ambiguity reporting: two phone numbers that
    /// share one asterisk mask. The restorer refuses both sites, so the user
    /// must be told the document came back still masked, and the session
    /// record must carry the refusal count.
    func testAmbiguousAsteriskMaskIsReportedToTheUserAndRecorded() async throws {
        let session = makeSession()
        session.outputStyleProvider = { .asterisk }

        let doc = try write("a.txt", "A: 13812345678 B: 13887655678.")
        await session.addDocuments([doc])
        await session.anonymizeAll()

        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertTrue(handoff.combined.contains("138****5678"), handoff.combined)
        let recordID = try XCTUnwrap(session.currentRecordID)

        let restored = try XCTUnwrap(session.restorePasted(handoff.combined))

        // Neither number is guessed back in; both sites stay masked.
        XCTAssertFalse(restored.text.contains("13812345678"))
        XCTAssertFalse(restored.text.contains("13887655678"))
        XCTAssertEqual(restored.restoredCount, 0)
        XCTAssertEqual(restored.ambiguousReplacements, ["138****5678"])

        // The GUI says why, rather than reporting a clean restore.
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(restored.ambiguousReplacements)
        )
        XCTAssertTrue(sentence.contains("138****5678"), sentence)
        XCTAssertTrue(sentence.contains("rather than guessed"), sentence)

        // And the session record keeps the refusal count for the report.
        let store = try SessionRecordStore(
            rootDirectory: workDir.appendingPathComponent("records")
        )
        let record = try XCTUnwrap(store.load(id: recordID, protection: .passphrase("pw")))
        XCTAssertEqual(record.restoreEvents.count, 1)
        XCTAssertEqual(record.restoreEvents[0].ambiguousCount, 1)
        XCTAssertEqual(record.restoreEvents[0].orphanCount, 0)
        XCTAssertEqual(record.restoreEvents[0].suspectCount, 0)
    }

    func testClipboardCompanionFollowsStyle() throws {
        let session = makeSession()
        session.outputStyleProvider = { .asterisk }

        let redacted = try session.redactClipboardText(
            "Call 13812345678 now.",
            createdAtISO8601: Self.createdAt
        )
        XCTAssertEqual(redacted.text, "Call 138****5678 now.")
        XCTAssertEqual(redacted.tokenCount, 1)
        XCTAssertEqual(session.sessionMapping?.style, .asterisk)
    }
}
