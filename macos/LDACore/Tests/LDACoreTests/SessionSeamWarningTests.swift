//
//  SessionSeamWarningTests.swift
//  LDACoreTests
//
//  The user-facing half of the session seam pass. SessionSeamTests covers the
//  engine: it repairs what it can and, when it cannot, reports the seam on
//  SessionTokenizeResult.unresolvedSeams instead of emitting a document that
//  restores to the wrong party. This file covers what happens to that list
//  afterwards, because a warning nobody is shown is the same defect wearing a
//  field name.
//
//  Three hops are checked with a real unrepairable seam, not a stub: the
//  headless facade (SessionAnonymizeResult), the CLI summary plus its stderr
//  notice, and the GUI hand-to-AI build plus its banner sentence. Each has a
//  negative control on an otherwise identical clean session, since an empty
//  list is exactly what a DROPPED field also looks like.
//
//  The fixture is the realistic shape: a matter reused from an earlier
//  engagement holds 甲公司 as a party's pseudonym, and the new document uses
//  甲公司 as ordinary contract boilerplate. Mint-time uniqueness only ever
//  checked new pseudonyms against this session's corpus, so the carried-in
//  entry was never checked against it, and nothing in the session emits that
//  replacement, so no remint can move it.
//
//  Deterministic-only sessions (no GGUF model required); hermetic temp-rooted
//  stores with passphrase protection, so no Keychain access.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore
@testable import LDAUI

@MainActor
final class SessionSeamWarningTests: XCTestCase {

    private static let createdAt = "2026-08-31T00:00:00Z"

    /// Boilerplate that spells the carried-in pseudonym, plus one email so the
    /// deterministic detector has something real to redact. Company detection
    /// is LLM-only, so 甲公司 stays ordinary text in these runs, which is the
    /// whole point: it is never a substitution site and restore replaces it
    /// anyway.
    private static let collidingText =
        "本合同由甲公司与丙方签署。联系 john@acme.com。"

    /// The same document without the colliding boilerplate. Everything else
    /// about the run is identical, so a difference in the warning can only
    /// come from the seam.
    private static let cleanText =
        "本合同由丁方与丙方签署。联系 john@acme.com。"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSeamWarningTests-\(UUID().uuidString)", isDirectory: true)
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

    /// The earlier matter's stored identities: 甲公司 already stands for a
    /// company that appears nowhere in this session.
    private func carriedInSeed() -> Mapping {
        Mapping(
            entries: [
                "甲公司": MappingEntry(
                    token: "甲公司",
                    value: "北京鼎盛科技有限公司",
                    type: .company,
                    surfaceText: "北京鼎盛科技有限公司",
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: "earlier matter",
            style: .pseudonym
        )
    }

    // MARK: - The facade carries the engine's verdict

    func testSessionAnonymizeReportsTheSeamItCouldNotRepair() throws {
        let document = try write("contract.txt", Self.collidingText)

        let result = try LDAService.anonymizeSession(
            inputs: [document],
            createdAtISO8601: Self.createdAt,
            seedMapping: carriedInSeed(),
            style: .pseudonym
        )

        XCTAssertEqual(result.unresolvedSeams.count, 1)
        let line = try XCTUnwrap(result.unresolvedSeams.first)
        XCTAssertTrue(line.hasPrefix("contract.txt:"), "the line must name the document: \(line)")
        XCTAssertTrue(line.contains("甲公司"), "the line must name the replacement: \(line)")
    }

    /// The reason this list is a correctness warning and not a diagnostic:
    /// the redacted output looks finished, and restoring it puts a party from
    /// a different engagement into this contract. If this assertion ever
    /// fails the fixture has stopped reproducing the defect, and the tests
    /// above would pass on a session that is actually fine.
    func testTheReportedSeamIsAGenuineWrongPartyRestore() throws {
        let document = try write("contract.txt", Self.collidingText)

        let result = try LDAService.anonymizeSession(
            inputs: [document],
            createdAtISO8601: Self.createdAt,
            seedMapping: carriedInSeed(),
            style: .pseudonym
        )

        let restored = Restorer.restore(
            text: result.documents[0].redactedMarkdown,
            mapping: result.mapping
        )
        XCTAssertFalse(result.unresolvedSeams.isEmpty, "fixture: the seam must be reported")
        XCTAssertTrue(
            restored.text.contains("北京鼎盛科技有限公司"),
            "fixture: restore must put the earlier matter's party into this contract"
        )
    }

    func testACleanSessionReportsNothingThroughTheFacade() throws {
        let document = try write("contract.txt", Self.cleanText)

        let result = try LDAService.anonymizeSession(
            inputs: [document],
            createdAtISO8601: Self.createdAt,
            seedMapping: carriedInSeed(),
            style: .pseudonym
        )

        XCTAssertTrue(result.unresolvedSeams.isEmpty)
    }

    // MARK: - CLI: the summary and the notice a person actually reads

    private func runCLISession(text: String) throws -> SessionSummaryJSON {
        let store = try ClientMappingStore(
            rootDirectory: workDir.appendingPathComponent("clients")
        )
        try store.save(carriedInSeed(), label: "Acme Matter", protection: .passphrase("pw"))
        let document = try write("contract.txt", text)

        return try LDACLI.runAnonymizeSession(
            inputs: [document],
            outputDir: workDir.appendingPathComponent("out-\(UUID().uuidString)"),
            passphrase: "pw",
            clientLabel: "Acme Matter",
            clientStore: store,
            style: .pseudonym,
            timestamp: { Self.createdAt }
        )
    }

    func testSessionSummaryJSONCarriesTheUnresolvedSeam() throws {
        let summary = try runCLISession(text: Self.collidingText)

        XCTAssertEqual(summary.unresolvedSeams.count, 1)
        let encoded = try CLIJSON.encode(summary)
        XCTAssertTrue(
            encoded.contains("\"unresolvedSeams\""),
            "the machine readable summary must carry the field: \(encoded)"
        )
    }

    func testACleanCLISessionReportsNoSeams() throws {
        let summary = try runCLISession(text: Self.cleanText)

        XCTAssertTrue(summary.unresolvedSeams.isEmpty)
    }

    func testSeamNoticeIsSilentWhenTheSessionIsClean() {
        XCTAssertNil(LDACLI.unresolvedSeamNotice(for: []))
    }

    func testSeamNoticeLeadsWithTheConsequenceAndQuotesEveryLine() throws {
        let notice = try XCTUnwrap(
            LDACLI.unresolvedSeamNotice(for: [
                "a.txt: first seam line.",
                "b.txt: second seam line."
            ])
        )

        XCTAssertTrue(notice.hasPrefix("Warning: 2 redacted sites"), notice)
        XCTAssertTrue(notice.contains("WRONG party"), notice)
        XCTAssertTrue(notice.contains("\n  a.txt: first seam line.\n"), notice)
        XCTAssertTrue(notice.contains("\n  b.txt: second seam line.\n"), notice)
        // The only lever this command has. Prescribing a GUI control here
        // would send the reader to something they cannot reach.
        XCTAssertTrue(notice.contains("--client"), notice)
        XCTAssertTrue(notice.contains("--style"), notice)
    }

    func testSeamNoticeCountsASingleSiteInTheSingular() throws {
        let notice = try XCTUnwrap(
            LDACLI.unresolvedSeamNotice(for: ["a.txt: only seam."])
        )

        XCTAssertTrue(notice.hasPrefix("Warning: 1 redacted site in this session"), notice)
        XCTAssertTrue(notice.contains("at that site"), notice)
    }

    // MARK: - GUI: the hand-to-AI build and its banner sentence

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
        session.recordStore = {
            try SessionRecordStore(rootDirectory: self.workDir.appendingPathComponent("records"))
        }
        session.recordProtection = { .passphrase("pw") }
        session.matterStore = {
            try MatterMetadataStore(rootDirectory: self.workDir.appendingPathComponent("matters"))
        }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.outputStyleProvider = { .pseudonym }
        return session
    }

    /// A session scoped to a matter whose stored mapping already holds the
    /// carried-in pseudonym, then handed one scanned document.
    private func makeSeededSession(text: String) async throws -> SessionModel {
        let store = try ClientMappingStore(
            rootDirectory: workDir.appendingPathComponent("clients")
        )
        try store.save(carriedInSeed(), label: "Matter A", protection: .passphrase("pw"))

        let session = makeSession()
        XCTAssertTrue(try session.selectMatter("Matter A", discardingDocuments: true))
        let document = try write("contract.txt", text)
        await session.addDocuments([document])
        await session.anonymizeAll()
        return session
    }

    func testHandToAIReportsTheSeamBeforeTheUserSendsTheCopy() async throws {
        let session = try await makeSeededSession(text: Self.collidingText)

        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertEqual(handoff.unresolvedSeams.count, 1)
        let line = try XCTUnwrap(handoff.unresolvedSeams.first)
        XCTAssertTrue(line.hasPrefix("contract.txt:"), "the line must name the document: \(line)")
        // The banner renders this list; a list the banner declines to render
        // is not surfaced.
        XCTAssertNotNil(
            AnonymizeWorkflowPresentation.unresolvedSeamAdvice(for: handoff.unresolvedSeams)
        )
    }

    /// The warning is advice, exactly like the rescan warning next to it: the
    /// copy is still built and still placed on the clipboard, because
    /// refusing to hand over a document is a decision for the user.
    func testHandToAIStillProducesTheCopyItIsWarningAbout() async throws {
        let session = try await makeSeededSession(text: Self.collidingText)

        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertFalse(handoff.unresolvedSeams.isEmpty, "fixture: the seam must be reported")
        XCTAssertEqual(handoff.documentCount, 1)
        XCTAssertFalse(handoff.combined.isEmpty)
    }

    func testACleanHandToAIReportsNoSeams() async throws {
        let session = try await makeSeededSession(text: Self.cleanText)

        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertTrue(handoff.unresolvedSeams.isEmpty)
    }
}
