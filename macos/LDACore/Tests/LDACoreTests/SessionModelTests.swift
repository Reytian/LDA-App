//
//  SessionModelTests.swift
//  LDACoreTests
//
//  Tests for the multi-document session view-model: the tray (add, remove,
//  .zip expansion), the hand-to-AI build (one shared mapping across the
//  session, client seeding, skipped-document reporting), paste-based restore,
//  and the add-a-missed-item correction on ReviewModel.
//
//  Deterministic-only (useLLM = false) so the GGUF model is never required;
//  the cross-document sweep test fakes the LLM layer through the extractor
//  seam instead. Hermetic: fixtures under FileManager.temporaryDirectory; the
//  client store uses a temp root and passphrase protection (no Keychain
//  access).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore
@testable import LDAUI

// MARK: - Scripted model fixtures

/// One scripted reply of the fake model: when a prompt carries the marker, the
/// model answers with this entity JSON.
private struct ScriptedReply {
    let marker: String
    let json: String
}

/// A fake LLM whose reply depends on which document's text reached the prompt,
/// so one session can hold documents the model treats differently. A document
/// matching no marker gets an empty entity list, which is how a missed party is
/// staged. File scope because several tests share it.
private struct ScriptedCompleter: TextCompleter {
    let replies: [ScriptedReply]

    func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
        for reply in replies where prompt.contains(reply.marker) {
            return reply.json
        }
        return #"{"entities":[]}"#
    }
}

@MainActor
final class SessionModelTests: XCTestCase {

    private static let createdAt = "2026-06-11T00:00:00Z"

    private var workDir: URL!

    /// Suites and store keys minted by this test instance.
    private var usedSuiteNames: [String] = []
    private var usedStorageKeys: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for name in usedSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        usedSuiteNames = []
        // LearningStore seals its blob under "store." + storageKey. Drop only
        // the process-unique keys this instance minted.
        for key in usedStorageKeys {
            LocalDataVault.deleteKey(account: StoreBlobKeys.vaultAccount(key))
        }
        usedStorageKeys = []
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A session whose models run deterministic-only (or, when a model path is
    /// given, with the AI pass enabled so the extractor seam can fake it) and
    /// whose client store lives under the temp root with passphrase protection.
    private func makeSession(modelPath: String? = nil) -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: modelPath)
                model.useLLM = modelPath != nil
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
        // Isolate the parked-session location: restorePasted and the file
        // restore flow resume a parked session just in time, and the default
        // location is the REAL Application Support directory, which may carry
        // a parked mapping from the developer's own use of the app.
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        // The legacy parked-label key lives in UserDefaults. Its production
        // domain is the standard one, which is shared by every concurrent test
        // process, so give each session a private suite.
        let legacy = legacyDefaults()
        session.legacyDefaults = { legacy }
        return session
    }

    /// A private UserDefaults suite standing in for the shared standard domain.
    private func legacyDefaults() -> UserDefaults {
        let (defaults, name) = TestNamespace.defaults("session-legacy")
        usedSuiteNames.append(name)
        return defaults
    }

    /// A session whose models run the AI pass against a scripted fake model.
    /// The caller must clear ReviewModel.llmExtractorFactoryForTesting.
    private func makeScriptedSession(_ replies: [ScriptedReply]) throws -> SessionModel {
        let dummyModel = workDir.appendingPathComponent("dummy.gguf")
        try Data("placeholder".utf8).write(to: dummyModel)
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in
            LLMExtractor(completer: ScriptedCompleter(replies: replies))
        }
        return makeSession(modelPath: dummyModel.path)
    }

    /// A hermetic learning store: its own UserDefaults suite, so a test never
    /// reads or writes what the developer's own use of the app has learned.
    private func freshLearningStore() -> LearningStore {
        let (defaults, name) = TestNamespace.defaults("session-learning")
        usedSuiteNames.append(name)
        let storageKey = TestNamespace.storeBaseKey("session-learning")
        usedStorageKeys.insert(storageKey)
        return LearningStore(defaults: defaults, storageKey: storageKey)
    }

    // MARK: - Tray

    func testAddDocumentsImportsAndSelectsLast() async throws {
        let session = makeSession()
        let doc1 = try write("a.txt", "Mail john@acme.com.")
        let doc2 = try write("b.txt", "Nothing sensitive.")

        await session.addDocuments([doc1, doc2])

        XCTAssertEqual(session.entries.count, 2)
        XCTAssertEqual(session.activeEntry?.name, "b.txt")
        XCTAssertEqual(session.entries[0].model.documentText, "Mail john@acme.com.")
    }

    func testAddDocumentsExpandsZip() async throws {
        let zipURL = workDir.appendingPathComponent("bundle.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data("Inside the archive.".utf8)
        try archive.addEntry(
            with: "inner.txt",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )

        let session = makeSession()
        await session.addDocuments([zipURL])

        XCTAssertEqual(session.entries.count, 1)
        XCTAssertEqual(session.entries[0].name, "inner.txt")
        XCTAssertEqual(session.entries[0].model.documentText, "Inside the archive.")
    }

    func testRemoveDocumentMovesSelection() async throws {
        let session = makeSession()
        let doc1 = try write("a.txt", "One.")
        let doc2 = try write("b.txt", "Two.")
        await session.addDocuments([doc1, doc2])

        let secondID = session.entries[1].id
        session.removeDocument(id: secondID)

        XCTAssertEqual(session.entries.count, 1)
        XCTAssertEqual(session.activeEntry?.name, "a.txt")
    }

    // MARK: - Hand to AI

    func testBuildHandToAISharesOneMappingAcrossDocuments() async throws {
        let session = makeSession()
        let doc1 = try write("a.txt", "Mail john@acme.com please.")
        let doc2 = try write("b.txt", "Also john@acme.com and mary@beta.io.")
        await session.addDocuments([doc1, doc2])
        await session.anonymizeAll()

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertEqual(result.documentCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
        // Combined markdown has neutral per-document headers and shared identities.
        XCTAssertTrue(result.combined.contains("# Document 1"))
        XCTAssertTrue(result.combined.contains("# Document 2"))
        XCTAssertFalse(result.combined.contains("a.txt"))
        XCTAssertFalse(result.combined.contains("b.txt"))
        XCTAssertFalse(result.combined.contains("john@acme.com"))
        let perDoc = result.perDocument
        let md1 = try XCTUnwrap(perDoc[session.entries[0].id])
        let md2 = try XCTUnwrap(perDoc[session.entries[1].id])
        XCTAssertTrue(md1.contains("{EMAIL_1}"))
        XCTAssertTrue(md2.contains("{EMAIL_1}"))
        XCTAssertTrue(md2.contains("{EMAIL_2}"))
        XCTAssertEqual(session.sessionMapping?.entries.count, 2)

        // Sealed token chips are visible after the build.
        XCTAssertEqual(session.entries[0].model.entities.first?.token, "{EMAIL_1}")
    }

    func testBuildHandToAIUsesNeutralHeadersInsteadOfSourceFilenames() async throws {
        let session = makeSession()
        let doc1 = try write("Alice Smith privileged.txt", "Mail john@acme.com please.")
        let doc2 = try write("Project Blue #12.txt", "Also mary@beta.io.")
        await session.addDocuments([doc1, doc2])
        await session.anonymizeAll()

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertTrue(result.combined.contains("# Document 1"))
        XCTAssertTrue(result.combined.contains("# Document 2"))
        XCTAssertFalse(result.combined.contains(doc1.lastPathComponent))
        XCTAssertFalse(result.combined.contains(doc2.lastPathComponent))
    }

    func testBuildHandToAISkipsUnanonymizedDocuments() async throws {
        let session = makeSession()
        let doc1 = try write("a.txt", "Mail john@acme.com.")
        let doc2 = try write("b.txt", "Not yet processed.")
        await session.addDocuments([doc1, doc2])
        // Anonymize only the first document.
        await session.entries[0].model.anonymize()

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertEqual(result.documentCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testBuildHandToAIReturnsNilWhenNothingReady() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Untouched.")
        await session.addDocuments([doc])

        XCTAssertNil(try session.buildHandToAI(createdAtISO8601: Self.createdAt))
    }

    func testPersonConfirmedInOneDocumentSurfacesForReviewInTheOthers() async throws {
        // Mirrors the headless session-wide sweep in LDAService.anonymizeSession
        // (LDAServiceSessionTests): the model reports the person in document 1
        // and misses them in document 2. In the GUI the swept mention must enter
        // document 2's REVIEW list as an ordinary entity (visible and
        // toggleable, never silently redacted) and then carry the shared token
        // in the handoff instead of leaking.
        let dummyModel = workDir.appendingPathComponent("dummy.gguf")
        try Data("placeholder".utf8).write(to: dummyModel)

        struct FirstDocumentOnlyCompleter: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                if prompt.contains("Witness statement") {
                    return #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
                }
                return #"{"entities":[]}"#
            }
        }
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in
            LLMExtractor(completer: FirstDocumentOnlyCompleter())
        }
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let session = makeSession(modelPath: dummyModel.path)
        let doc1 = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        let doc2 = try write("b.txt", "The filing was prepared for Jordan Marlowe this week.")
        await session.addDocuments([doc1, doc2])
        await session.anonymizeAll()

        // Fixture guards: document 1 detected the person and document 2's AI
        // pass ran cleanly (it just missed the party).
        XCTAssertTrue(
            session.entries[0].model.entities.contains { $0.span.text == "Jordan Marlowe" },
            "fixture: the model must report the person in document 1"
        )
        XCTAssertNil(session.entries[1].model.aiWarning)

        // The swept mention is an ordinary review entity in document 2.
        let swept = session.entries[1].model.entities.filter { $0.span.text == "Jordan Marlowe" }
        XCTAssertEqual(
            swept.count,
            1,
            "the party confirmed in document 1 must surface in document 2's review list"
        )
        XCTAssertTrue(swept.allSatisfy { $0.accepted })

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        let md1 = try XCTUnwrap(result.perDocument[session.entries[0].id])
        let md2 = try XCTUnwrap(result.perDocument[session.entries[1].id])
        XCTAssertFalse(
            md2.contains("Jordan Marlowe"),
            "a party confirmed in document 1 must not leak from document 2"
        )
        XCTAssertTrue(md1.contains("{PERSON_1}"))
        XCTAssertTrue(md2.contains("{PERSON_1}"), "both documents share one token for the person")
    }

    // MARK: - Cross-document re-scan warning (handoff seam)

    func testHandToAIWarnsWhenAPartnerPartyWasConfirmedAfterThisDocumentScanned() async throws {
        // The residual gap the tray sweep leaves: it runs at DETECT time, so a
        // document scanned while it was alone in the tray never sees the party
        // a partner confirms afterwards, and nothing tells the user. The
        // handoff, which holds every ready document at once, says so.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let unscanned = try write("b.txt", "The filing was prepared for Jordan Marlowe this week.")
        await session.addDocuments([unscanned])
        await session.anonymizeAll()

        let witness = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        await session.addDocuments([witness])
        await session.anonymizeAll()

        // Fixture guards: a.txt confirmed the party, and b.txt (scanned first)
        // never picked it up.
        XCTAssertTrue(
            session.entries[1].model.entities.contains { $0.span.text == "Jordan Marlowe" },
            "fixture: the model must report the person in a.txt"
        )
        XCTAssertFalse(
            session.entries[0].model.entities.contains { $0.span.text == "Jordan Marlowe" },
            "fixture: b.txt scanned before a.txt joined the tray, so it never swept the party"
        )

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertEqual(result.rescanWarnings.map(\.documentName), ["b.txt"])
        XCTAssertEqual(result.rescanWarnings.first?.entryID, session.entries[0].id)
        XCTAssertEqual(result.rescanWarnings.first?.missedPartyCount, 1)
    }

    func testHandToAIRescanWarningNeverAddsSpansOrRedacts() async throws {
        // The human-review invariant: the warning is advice, not an edit. The
        // unscanned document keeps exactly the spans its own pass produced and
        // its Markdown still carries the party in the clear, which is the
        // leak the warning exists to point at.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let unscanned = try write("b.txt", "The filing was prepared for Jordan Marlowe this week.")
        await session.addDocuments([unscanned])
        await session.anonymizeAll()
        let witness = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        await session.addDocuments([witness])
        await session.anonymizeAll()

        let spansBefore = session.entries[0].model.entities.map(\.span)
        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertFalse(result.rescanWarnings.isEmpty, "fixture: the seam must be reported")
        XCTAssertEqual(
            session.entries[0].model.entities.map(\.span),
            spansBefore,
            "building the handoff must not add a span the user never reviewed"
        )
        let markdown = try XCTUnwrap(result.perDocument[session.entries[0].id])
        XCTAssertTrue(
            markdown.contains("Jordan Marlowe"),
            "the warning reports the leak, it does not silently redact it"
        )
    }

    func testHandToAIDoesNotWarnWhenTheTraySweepAlreadyCoveredTheParty() async throws {
        // The negative control for the warning: both documents were in the
        // tray before Scan ran, so the sweep already pulled the party into
        // b.txt's review list. Sending the user back to re-scan would be noise.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let witness = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        let other = try write("b.txt", "The filing was prepared for Jordan Marlowe this week.")
        await session.addDocuments([witness, other])
        await session.anonymizeAll()

        // Fixture guard: without this the test would also pass if the sweep
        // itself stopped working and b.txt simply had no party to compare.
        XCTAssertTrue(
            session.entries[1].model.entities.contains { $0.span.text == "Jordan Marlowe" },
            "fixture: the tray sweep must have pulled the party into b.txt"
        )

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertTrue(result.rescanWarnings.isEmpty)
    }

    func testHandToAIDoesNotWarnForNeedlesTooShortToRescan() async throws {
        // The warning reuses EntityRescan's needle-safety filter, so it can
        // never report a gap the sweep would refuse to close. A two-character
        // Latin surname is below the rescan threshold: flagging every document
        // that happens to contain the word would train the user to ignore the
        // banner.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Li","type":"PERSON"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let unscanned = try write("b.txt", "Li reviewed the filing this week.")
        await session.addDocuments([unscanned])
        await session.anonymizeAll()
        let witness = try write("a.txt", "Witness statement: Li attended the hearing.")
        await session.addDocuments([witness])
        await session.anonymizeAll()

        XCTAssertTrue(
            session.entries[1].model.entities.contains { $0.span.text == "Li" },
            "fixture: the short surname must be confirmed in a.txt for the filter to matter"
        )

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertTrue(result.rescanWarnings.isEmpty)
    }

    func testHandToAIDoesNotWarnWhenTheSurfaceSitsInsideALongerAcceptedSpan() async throws {
        // b.txt confirmed the company on its own, and its only mention of the
        // partner's person surface sits inside that accepted span, so the text
        // is already covered. The sweep blocks such occurrences and so must
        // the warning.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
            ),
            ScriptedReply(
                marker: "The filing",
                json: #"{"entities":[{"value":"Jordan Marlowe Holdings","type":"COMPANY"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let company = try write("b.txt", "The filing was prepared by Jordan Marlowe Holdings this week.")
        await session.addDocuments([company])
        await session.anonymizeAll()
        let witness = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        await session.addDocuments([witness])
        await session.anonymizeAll()

        XCTAssertTrue(
            session.entries[0].model.entities.contains { $0.span.text == "Jordan Marlowe Holdings" },
            "fixture: b.txt must confirm the longer company surface"
        )

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertTrue(result.rescanWarnings.isEmpty)
    }

    func testHandToAIDoesNotPrescribeARescanASuppressedTermWouldRefuseToClose() async throws {
        // The stuck-banner seam. Learned suppression is applied AFTER the
        // rescan sweep (ReviewModelDetection), so a party the user has net
        // rejected is swept into the candidate list and then dropped again:
        // re-scanning can never close this gap. The warning itself stays
        // truthful (the document really does still carry the party), but the
        // sentence must stop sending the user to a button that cannot help.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        // What an earlier export left behind: one net rejection is enough.
        let learning = freshLearningStore()
        learning.record(accepted: [], rejected: [("Jordan Marlowe", .person)])
        XCTAssertTrue(
            learning.suppressKeys.contains(LearningStore.key(value: "Jordan Marlowe", type: .person)),
            "fixture: a single net rejection must suppress the term"
        )
        session.configureNewModel = { $0.learningStore = ScopedLearningStore(global: learning) }

        let unscanned = try write("b.txt", "The filing was prepared for Jordan Marlowe this week.")
        await session.addDocuments([unscanned])
        await session.anonymizeAll()

        let witness = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        await session.addDocuments([witness])
        await session.anonymizeAll()
        // Suppression hides the party from a.txt's detection too, so the user
        // confirms it by hand, the one path that bypasses the learned filter.
        XCTAssertEqual(
            session.entries[1].model.addManualEntity(text: "Jordan Marlowe", type: .person),
            1,
            "fixture: the party must be confirmed in a.txt for the seam to exist"
        )

        // The gap really is unclosable: running Scan on b.txt again, exactly
        // what the banner used to prescribe, changes nothing.
        let spansBeforeRescan = session.entries[0].model.entities.map(\.span)
        await session.entries[0].model.anonymize()
        XCTAssertEqual(
            session.entries[0].model.entities.map(\.span),
            spansBeforeRescan,
            "fixture: suppression drops the swept party, so the re-scan is a no-op"
        )

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let warning = try XCTUnwrap(result.rescanWarnings.first)
        XCTAssertEqual(result.rescanWarnings.map(\.documentName), ["b.txt"])
        XCTAssertEqual(warning.missedPartyCount, 1)
        XCTAssertEqual(warning.suppressedPartyCount, 1)
        XCTAssertEqual(warning.rescannablePartyCount, 0)

        let advice = try XCTUnwrap(
            AnonymizeWorkflowPresentation.rescanAdvice(for: result.rescanWarnings)
        )
        XCTAssertTrue(advice.contains("b.txt"), "the banner must still name the document")
        XCTAssertFalse(
            advice.contains("Run Scan"),
            "re-scanning sweeps the party in and suppression drops it again"
        )
        XCTAssertTrue(
            advice.contains("Protect a missed item"),
            "the honest action for a suppressed term is to confirm it by hand"
        )
    }

    func testHandToAIStillPrescribesARescanForAPartyLearningNeverSuppressed() async throws {
        // The control for the case above: an active learning store that has
        // nothing to say about this party must not weaken the advice.
        let session = try makeScriptedSession([
            ScriptedReply(
                marker: "Witness statement",
                json: #"{"entities":[{"value":"Jordan Marlowe","type":"PERSON"}]}"#
            )
        ])
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let learning = freshLearningStore()
        learning.record(accepted: [], rejected: [("Schedule A", .company)])
        session.configureNewModel = { $0.learningStore = ScopedLearningStore(global: learning) }

        let unscanned = try write("b.txt", "The filing was prepared for Jordan Marlowe this week.")
        await session.addDocuments([unscanned])
        await session.anonymizeAll()
        let witness = try write("a.txt", "Witness statement: Jordan Marlowe attended the hearing.")
        await session.addDocuments([witness])
        await session.anonymizeAll()

        let result = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let warning = try XCTUnwrap(result.rescanWarnings.first)
        XCTAssertEqual(warning.missedPartyCount, 1)
        XCTAssertEqual(warning.suppressedPartyCount, 0)
        let advice = try XCTUnwrap(
            AnonymizeWorkflowPresentation.rescanAdvice(for: result.rescanWarnings)
        )
        XCTAssertTrue(advice.contains("Run Scan on it again"))
    }

    func testClientIdentitiesPersistAcrossSessions() async throws {
        // Session 1 under the client.
        let first = makeSession()
        first.selectClient("Acme Matter")
        let doc1 = try write("a.txt", "Mail john@acme.com.")
        await first.addDocuments([doc1])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        // A brand new session (app relaunch), same client.
        let second = makeSession()
        second.selectClient("Acme Matter")
        let doc2 = try write("b.txt", "Reach john@acme.com or mary@beta.io.")
        await second.addDocuments([doc2])
        await second.anonymizeAll()
        let result = try XCTUnwrap(second.buildHandToAI(createdAtISO8601: Self.createdAt))

        let markdown = try XCTUnwrap(result.perDocument[second.entries[0].id])
        XCTAssertTrue(markdown.contains("{EMAIL_1}"), "the client's known address keeps its token")
        XCTAssertTrue(markdown.contains("{EMAIL_2}"), "the new address continues the counter")
    }

    // MARK: - Export for AI

    /// A destination standing in for the save panel's choice: a fresh folder,
    /// and passphrase protection for the sidecar so the test never touches
    /// the Keychain.
    private func exportDestination(
        _ session: SessionModel,
        name: String = "Redacted for AI.md"
    ) throws -> URL {
        let folder = workDir.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session.exportSidecarProtection = { _ in .passphrase("sidecar-pw") }
        return folder.appendingPathComponent(name)
    }

    private func filesWritten(nextTo destination: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .sorted()
    }

    func testExportForAIWritesOneMarkdownAndOneSidecarAndInheritsTheHandoffSideEffects() async throws {
        let session = makeSession()
        let doc1 = try write("a.txt", "Mail john@acme.com please.")
        let doc2 = try write("b.txt", "Also mary@beta.io.")
        let doc3 = try write("c.txt", "Not scanned yet.")
        await session.addDocuments([doc1, doc2, doc3])
        await session.entries[0].model.anonymize()
        await session.entries[1].model.anonymize()
        let destination = try exportDestination(session)

        let result = try XCTUnwrap(
            session.exportForAI(to: destination, createdAtISO8601: Self.createdAt)
        )

        // Exactly one .md and one .ldamap land in the chosen folder.
        XCTAssertEqual(try filesWritten(nextTo: destination), ["Redacted for AI.ldamap", "Redacted for AI.md"])
        XCTAssertEqual(result.markdownURL, destination)
        XCTAssertEqual(
            result.mappingURL,
            destination.deletingPathExtension().appendingPathExtension("ldamap")
        )

        // The body is the token-style preamble followed by the combined handoff.
        let markdown = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(
            markdown.hasPrefix(MarkdownHandoffWriter.tokenStylePreamble + "\n\n# Document 1\n\n"),
            markdown
        )
        XCTAssertTrue(markdown.contains("{EMAIL_1}"))
        XCTAssertTrue(markdown.contains("# Document 2"))
        XCTAssertFalse(markdown.contains("john@acme.com"))
        XCTAssertFalse(markdown.contains("a.txt"))

        // The sidecar is the session mapping, under the injected protection.
        let sidecar = try MappingStore.load(from: result.mappingURL, protection: .passphrase("sidecar-pw"))
        XCTAssertEqual(sidecar, try XCTUnwrap(session.sessionMapping))

        // Every side effect of buildHandToAI is inherited, none re-implemented.
        XCTAssertNotNil(session.currentRecordID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try session.parkedMappingURL().path))
        XCTAssertEqual(session.entries[0].model.entities.first?.token, "{EMAIL_1}")
        XCTAssertEqual(result.documentCount, 2)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(
            result.includedDocumentIDs,
            Set([session.entries[0].id, session.entries[1].id])
        )
    }

    func testExportForAIWritesNothingAndChangesNothingWhenNoDocumentIsReady() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Untouched.")
        await session.addDocuments([doc])
        let destination = try exportDestination(session)

        XCTAssertNil(try session.exportForAI(to: destination, createdAtISO8601: Self.createdAt))

        XCTAssertEqual(try filesWritten(nextTo: destination), [])
        XCTAssertNil(session.sessionMapping)
        XCTAssertNil(session.currentRecordID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try session.parkedMappingURL().path))
    }

    func testExportForAIKeysTheSidecarByTheChosenBaseName() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        let destination = try exportDestination(session, name: "Matter 12 for AI.md")
        var accounts: [String] = []
        session.exportSidecarProtection = { account in
            accounts.append(account)
            return .passphrase("sidecar-pw")
        }

        _ = try session.exportForAI(to: destination, createdAtISO8601: Self.createdAt)

        // Restore derives the same account from the sidecar's base name, so
        // the two sides agree without any record of the choice.
        XCTAssertEqual(accounts, ["Matter 12 for AI"])
        XCTAssertEqual(try filesWritten(nextTo: destination), ["Matter 12 for AI.ldamap", "Matter 12 for AI.md"])
    }

    func testExportForAIWritesNoPreambleInPseudonymStyle() async throws {
        let session = makeSession()
        session.outputStyleProvider = { .pseudonym }
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        let destination = try exportDestination(session)

        _ = try XCTUnwrap(session.exportForAI(to: destination, createdAtISO8601: Self.createdAt))

        let markdown = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Protected values appear as placeholders"), markdown)
        XCTAssertFalse(markdown.contains("john@acme.com"))
        XCTAssertEqual(try MappingStore.load(from: SessionModel.sidecarURL(for: destination), protection: .passphrase("sidecar-pw")).style, .pseudonym)
    }

    func testRequestExportForAIBumpsTheToken() {
        let session = makeSession()

        session.requestExportForAI()

        XCTAssertEqual(session.exportForAIRequestToken, 1)
    }

    // MARK: - Bring back and restore

    func testRestorePastedRoundTripsEditedMarkdown() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let edited = "AI draft follows. " + handoff.combined
        let restored = try XCTUnwrap(session.restorePasted(edited))

        XCTAssertEqual(restored.text, "AI draft follows. Mail john@acme.com please.")
        XCTAssertTrue(restored.orphanTokens.isEmpty)
        XCTAssertTrue(restored.suspectPlaceholders.isEmpty)
    }

    func testRestorePastedFlagsMangledPlaceholder() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        _ = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let restored = try XCTUnwrap(session.restorePasted("Mail [EMAIL_1] please."))

        XCTAssertEqual(restored.restoredCount, 0)
        XCTAssertEqual(restored.suspectPlaceholders, ["[EMAIL_1]"])
    }

    func testRestorePastedWithoutMappingReturnsNil() throws {
        let session = makeSession()
        XCTAssertNil(try session.restorePasted("Anything {EMAIL_1} here."))
    }

    // MARK: - Menu-bar companion (clipboard round-trip)

    func testRedactClipboardTextTokenizesAndExtendsSessionMapping() throws {
        let session = makeSession()

        let redacted = try session.redactClipboardText(
            "Contact john@acme.com today.",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(redacted.text, "Contact {EMAIL_1} today.")
        XCTAssertEqual(redacted.tokenCount, 1)
        XCTAssertEqual(session.sessionMapping?.entries.count, 1)

        // The companion's own restore closes the loop.
        let restored = try XCTUnwrap(session.restorePasted(redacted.text))
        XCTAssertEqual(restored.text, "Contact john@acme.com today.")
    }

    func testRedactClipboardTextReusesSessionIdentities() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        _ = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        // The clipboard snippet mentions the same address: same token.
        let redacted = try session.redactClipboardText(
            "Remind john@acme.com about the filing.",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(redacted.text, "Remind {EMAIL_1} about the filing.")
    }

    func testRedactClipboardTextPersistsUnderClient() throws {
        let first = makeSession()
        first.selectClient("Acme Matter")
        _ = try first.redactClipboardText(
            "Mail john@acme.com.",
            createdAtISO8601: Self.createdAt
        )

        // A fresh session under the same client keeps the identity.
        let second = makeSession()
        second.selectClient("Acme Matter")
        let redacted = try second.redactClipboardText(
            "Ping john@acme.com and mary@beta.io.",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertTrue(redacted.text.contains("{EMAIL_1}"))
        XCTAssertTrue(redacted.text.contains("{EMAIL_2}"))
    }

    func testRestorePastedFallsBackToClientMapping() async throws {
        // Build under a client, then simulate an app relaunch: a fresh session
        // with no in-memory mapping restores via the client's stored mapping.
        let first = makeSession()
        first.selectClient("Acme Matter")
        let doc = try write("a.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        let handoff = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        let relaunched = makeSession()
        relaunched.selectClient("Acme Matter")
        let restored = try XCTUnwrap(relaunched.restorePasted(handoff.combined))

        XCTAssertEqual(restored.text, "Mail john@acme.com.")
    }

    func testSelectingAnotherClientClearsThePreviousRoundTripContext() async throws {
        let session = makeSession()
        session.selectClient("Acme Matter")
        let doc = try write("a.txt", "Mail john@acme.com.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        _ = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertNotNil(session.sessionMapping)
        XCTAssertNotNil(session.currentRecordID)
        XCTAssertNotNil(session.entries[0].model.entities.first?.token)
        let priorModel = session.entries[0].model

        XCTAssertFalse(session.selectClient("Beta Matter"))
        XCTAssertEqual(session.clientLabel, "Acme Matter")
        XCTAssertNotNil(session.sessionMapping)
        XCTAssertEqual(session.entries.count, 1)

        XCTAssertTrue(session.selectClient("Beta Matter", discardingDocuments: true))

        XCTAssertEqual(session.clientLabel, "Beta Matter")
        XCTAssertNil(session.sessionMapping)
        XCTAssertNil(session.currentRecordID)
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertNil(priorModel.entities.first?.token)
    }

    func testParkedMappingForAnotherClientIsNotResumed() async throws {
        let first = makeSession()
        first.selectClient("Acme Matter")
        let doc = try write("a.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        let second = makeSession()
        second.selectClient("Beta Matter")
        second.resumeParkedSession()

        XCTAssertEqual(second.clientLabel, "Beta Matter")
        XCTAssertNil(second.sessionMapping)
    }

    func testExplicitNoClientDoesNotResumeAParkedClientMapping() async throws {
        let first = makeSession()
        first.selectClient("Acme Matter")
        let doc = try write("a.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        let second = makeSession()
        XCTAssertTrue(second.selectClient(nil))
        second.resumeParkedSession()

        XCTAssertNil(second.clientLabel)
        XCTAssertNil(second.sessionMapping)
    }

    func testParkedMatterLabelIsEncryptedAndResumesWithoutUserDefaults() async throws {
        // One private suite shared by both sessions, standing in for the
        // production standard domain. Private rather than standard because the
        // standard domain is one domain per user: a concurrent test process
        // writing the same key could make this assertion pass or fail for a
        // reason that has nothing to do with the code under test. A fresh suite
        // also starts genuinely empty, which lets the assertion be the stronger
        // one below (nothing at all was written, not merely no label).
        let (defaults, suiteName) = TestNamespace.defaults("parked-label")
        usedSuiteNames.append(suiteName)

        let first = makeSession()
        first.legacyDefaults = { defaults }
        first.selectClient("Acme Privileged Matter")
        let doc = try write("parked.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertNil(defaults.string(forKey: SessionModel.parkedClientLabelKey))
        XCTAssertEqual(
            (defaults.persistentDomain(forName: suiteName) ?? [:]).keys.sorted(), [],
            "parking must write nothing to UserDefaults, not merely no label"
        )
        let parkedBytes = try Data(contentsOf: first.parkedMappingURL())
        XCTAssertNil(
            String(data: parkedBytes, encoding: .utf8)?.range(of: "Acme Privileged Matter")
        )

        // The same empty suite: the label can only have come from the
        // encrypted parked file.
        let relaunched = makeSession()
        relaunched.legacyDefaults = { defaults }
        relaunched.resumeParkedSession()

        XCTAssertEqual(relaunched.clientLabel, "Acme Privileged Matter")
        XCTAssertNotNil(relaunched.sessionMapping)
    }

    func testStaleParkedAliasResumesUnderTheCurrentMatterName() async throws {
        let first = makeSession()
        first.selectClient("Alpha Matter")
        let doc = try write("stale-parked.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))
        try first.renameMatter(from: "Alpha Matter", to: "Beta Matter")

        let parkedURL = try first.parkedMappingURL()
        var stale = try ParkedSessionStore.load(
            from: parkedURL,
            protection: first.parkedProtection()
        )
        stale.clientLabel = "Alpha Matter"
        stale.mapping.sourceFile = "Alpha Matter"
        try ParkedSessionStore.save(
            stale,
            to: parkedURL,
            protection: first.parkedProtection()
        )

        let relaunched = makeSession()
        relaunched.resumeParkedSession()

        XCTAssertEqual(relaunched.clientLabel, "Beta Matter")
        XCTAssertEqual(relaunched.sessionMapping?.sourceFile, "Beta Matter")
    }

    func testHandoffSurfacesAParkedSessionWriteFailure() async throws {
        let session = makeSession()
        let doc = try write("parking-failure.txt", "Mail john@acme.com.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        session.saveParkedSession = { _, _, _ in
            throw DocumentIOError.unreadable("Simulated parked-session failure")
        }

        XCTAssertThrowsError(
            try session.buildHandToAI(createdAtISO8601: Self.createdAt)
        )
    }

    func testConfirmedMatterSwitchRemovesTheOutgoingParkedSession() async throws {
        let first = makeSession()
        first.selectClient("Alpha Matter")
        let doc = try write("switch-parked.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))
        let parkedURL = try first.parkedMappingURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkedURL.path))

        XCTAssertTrue(
            try first.selectMatter("Beta Matter", discardingDocuments: true)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: parkedURL.path))
        let relaunched = makeSession()
        relaunched.resumeParkedSession()
        XCTAssertNil(relaunched.sessionMapping)
    }

    func testColdLaunchSwitchRequiresConfirmationForDormantParkedWork() async throws {
        let first = makeSession()
        first.selectClient("Alpha Matter")
        let doc = try write("cold-switch.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))
        let parkedURL = try first.parkedMappingURL()

        let relaunched = makeSession()
        XCTAssertFalse(try relaunched.selectMatter("Beta Matter"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkedURL.path))

        XCTAssertTrue(
            try relaunched.selectMatter("Beta Matter", discardingDocuments: true)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: parkedURL.path))
        XCTAssertEqual(relaunched.clientLabel, "Beta Matter")
    }

    func testArchivedParkedMatterCannotResume() async throws {
        let first = makeSession()
        first.selectClient("Acme Matter")
        let doc = try write("archived-parked.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))
        try first.matterStore().setArchived(
            label: "Acme Matter",
            isArchived: true,
            protection: first.matterProtection()
        )

        let relaunched = makeSession()
        relaunched.resumeParkedSession()

        XCTAssertNil(relaunched.clientLabel)
        XCTAssertNil(relaunched.sessionMapping)
    }

    func testConfirmedArchiveRemovesTheMatterParkedSession() async throws {
        let session = makeSession()
        session.selectClient("Acme Matter")
        let doc = try write("archive-confirmed.txt", "Mail john@acme.com.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        _ = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        let parkedURL = try session.parkedMappingURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkedURL.path))

        XCTAssertTrue(
            try session.setMatterArchived(
                "Acme Matter",
                isArchived: true,
                discardingDocuments: true
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: parkedURL.path))
        XCTAssertNil(session.clientLabel)
        XCTAssertNil(session.sessionMapping)
    }

    func testDiscardingDocumentsCancelsTheRestOfAnActiveImport() async throws {
        let session = makeSession()
        session.selectClient("Acme Matter")
        let firstURL = try write("first.txt", "Mail john@acme.com.")
        let secondURL = try write("second.txt", "Mail mary@beta.io.")
        let importStarted = expectation(description: "first import started")
        var releaseImport: CheckedContinuation<Void, Never>?

        session.openDocument = { model, url in
            importStarted.fulfill()
            await withCheckedContinuation { continuation in
                releaseImport = continuation
            }
            await model.open(url)
        }

        let importTask = Task {
            await session.addDocuments([firstURL, secondURL])
        }
        await fulfillment(of: [importStarted], timeout: 1)

        XCTAssertFalse(session.selectClient("Beta Matter"))
        XCTAssertTrue(session.selectClient("Beta Matter", discardingDocuments: true))
        releaseImport?.resume()
        await importTask.value

        XCTAssertEqual(session.clientLabel, "Beta Matter")
        XCTAssertTrue(session.entries.isEmpty)
    }

    func testRenameMatterMigratesMappingAndKeepsOldHistoryTogether() throws {
        let session = makeSession()
        session.selectClient("Acme Matter")
        _ = try session.redactClipboardText(
            "Contact john@acme.com.",
            createdAtISO8601: Self.createdAt
        )
        let oldRecord = SessionRecord(
            createdAtISO8601: Self.createdAt,
            clientLabel: "Acme Matter",
            documents: [],
            protectedValueCount: 1
        )
        try session.recordStore().save(oldRecord, protection: session.recordProtection())

        try session.renameMatter(from: "Acme Matter", to: "Acme Transaction")

        XCTAssertEqual(session.clientLabel, "Acme Transaction")
        let clientStore = try ClientMappingStore(
            rootDirectory: workDir.appendingPathComponent("clients")
        )
        XCTAssertNil(
            try clientStore.load(label: "Acme Matter", protection: .passphrase("pw"))
        )
        let renamedMapping = try XCTUnwrap(
            try clientStore.load(label: "Acme Transaction", protection: .passphrase("pw"))
        )
        XCTAssertEqual(renamedMapping.entries.count, 1)

        let metadata = try session.matterMetadata().metadata
        XCTAssertEqual(metadata.first?.label, "Acme Transaction")
        XCTAssertEqual(metadata.first?.aliases, ["Acme Matter"])
        let summaries = MatterWorkspacePresentation.summaries(
            clientLabels: ["Acme Transaction"],
            records: [oldRecord],
            metadata: metadata
        )
        XCTAssertEqual(summaries.map(\.label), ["Acme Transaction"])
        XCTAssertEqual(summaries.first?.sessionCount, 1)
    }

    func testRenameMatterRejectsARecordOnlyDestination() throws {
        let session = makeSession()
        session.selectClient("Alpha Matter")
        let occupied = SessionRecord(
            createdAtISO8601: Self.createdAt,
            clientLabel: "Beta Matter",
            documents: [],
            protectedValueCount: 0
        )
        try session.recordStore().save(occupied, protection: session.recordProtection())

        XCTAssertThrowsError(
            try session.renameMatter(from: "Alpha Matter", to: "Beta Matter")
        )
        XCTAssertEqual(session.clientLabel, "Alpha Matter")
    }

    func testRenameStopsBeforeChangingMatterWhenParkedStateCannotBeRewritten() throws {
        let session = makeSession()
        session.selectClient("Alpha Matter")
        _ = try session.redactClipboardText(
            "Contact john@acme.com.",
            createdAtISO8601: Self.createdAt
        )
        let mapping = try XCTUnwrap(session.sessionMapping)
        try ParkedSessionStore.save(
            ParkedSessionState(mapping: mapping, clientLabel: "Alpha Matter"),
            to: session.parkedMappingURL(),
            protection: session.parkedProtection()
        )
        session.saveParkedSession = { _, _, _ in
            throw DocumentIOError.unreadable("Simulated parked-session failure")
        }

        XCTAssertThrowsError(
            try session.renameMatter(from: "Alpha Matter", to: "Beta Matter")
        )

        XCTAssertEqual(session.clientLabel, "Alpha Matter")
        let store = try ClientMappingStore(
            rootDirectory: workDir.appendingPathComponent("clients")
        )
        XCTAssertNotNil(
            try store.load(label: "Alpha Matter", protection: .passphrase("pw"))
        )
        XCTAssertNil(
            try store.load(label: "Beta Matter", protection: .passphrase("pw"))
        )
    }

    func testSelectingARenamedAliasIsRejectedInsteadOfRecreatingIt() throws {
        let session = makeSession()
        try session.matterStore().rename(
            from: "Alpha Matter",
            to: "Beta Matter",
            protection: session.matterProtection()
        )

        XCTAssertThrowsError(try session.selectMatter("Alpha Matter")) { error in
            guard case MatterManagementError.reservedAlias(
                "Alpha Matter",
                currentLabel: "Beta Matter"
            ) = error else {
                return XCTFail("Expected a reserved alias error, got \(error)")
            }
        }
        XCTAssertNil(session.clientLabel)
    }

    func testArchivedMatterMustBeRestoredBeforeSelection() throws {
        let session = makeSession()
        try session.matterStore().setArchived(
            label: "Acme Matter",
            isArchived: true,
            protection: session.matterProtection()
        )

        XCTAssertThrowsError(try session.selectMatter("Acme Matter")) { error in
            guard case MatterManagementError.archivedMatter("Acme Matter") = error else {
                return XCTFail("Expected an archived matter error, got \(error)")
            }
        }
        XCTAssertNil(session.clientLabel)
    }

    func testMatterSelectionStopsWhenWorkspaceIdentityDataIsLocked() throws {
        let session = makeSession()
        try session.matterStore().setArchived(
            label: "Locked Matter",
            isArchived: false,
            protection: .passphrase("different-password")
        )

        XCTAssertThrowsError(try session.selectMatter("New Matter")) { error in
            guard case MatterManagementError.incompleteWorkspace = error else {
                return XCTFail("Expected an incomplete workspace error, got \(error)")
            }
        }
        XCTAssertNil(session.clientLabel)
    }

    func testArchiveRequiresConfirmationForOpenDocumentsAndCanBeReversed() async throws {
        let session = makeSession()
        session.selectClient("Acme Matter")
        await session.addDocuments([try write("active.txt", "Privileged draft")])

        XCTAssertFalse(
            try session.setMatterArchived("Acme Matter", isArchived: true)
        )
        XCTAssertEqual(session.entries.count, 1)
        XCTAssertEqual(session.clientLabel, "Acme Matter")

        XCTAssertTrue(
            try session.setMatterArchived(
                "Acme Matter",
                isArchived: true,
                discardingDocuments: true
            )
        )
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertNil(session.clientLabel)
        XCTAssertTrue(try XCTUnwrap(session.matterMetadata().metadata.first).isArchived)

        XCTAssertTrue(
            try session.setMatterArchived("Acme Matter", isArchived: false)
        )
        XCTAssertFalse(try XCTUnwrap(session.matterMetadata().metadata.first).isArchived)
    }

    func testArchiveRequiresConfirmationForAnActiveClipboardRoundTrip() throws {
        let session = makeSession()
        session.selectClient("Acme Matter")
        _ = try session.redactClipboardText(
            "Contact john@acme.com.",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertFalse(
            try session.setMatterArchived("Acme Matter", isArchived: true)
        )
        XCTAssertEqual(session.clientLabel, "Acme Matter")

        XCTAssertTrue(
            try session.setMatterArchived(
                "Acme Matter",
                isArchived: true,
                discardingDocuments: true
            )
        )
        XCTAssertNil(session.clientLabel)
        XCTAssertNil(session.sessionMapping)
    }
}

// MARK: - Add a missed item (R5)

@MainActor
final class ReviewModelManualEntityTests: XCTestCase {

    private func makeModel(text: String) -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.documentText = text
        return model
    }

    func testAddManualEntityFindsEveryOccurrence() {
        let model = makeModel(text: "Garcia met Garcia at the Garcia hearing.")

        let added = model.addManualEntity(text: "Garcia", type: .person)

        XCTAssertEqual(added, 3)
        XCTAssertEqual(model.entities.count, 3)
        XCTAssertTrue(model.entities.allSatisfy { $0.accepted })
        XCTAssertTrue(model.entities.allSatisfy { $0.span.source == .manual })
    }

    func testAddManualEntitySkipsOverlapsWithExistingEntities() {
        let model = makeModel(text: "Call +1 212 555 0000 about Garcia.")
        // Detect the phone deterministically first.
        let spans = DeterministicEngine().detect(model.documentText)
        model.entities = spans.map { ReviewEntity(span: $0, accepted: true) }
        let before = model.entities.count

        // "212" lives inside the detected phone; adding it must not double up.
        let added = model.addManualEntity(text: "212", type: .amount)

        XCTAssertEqual(added, 0)
        XCTAssertEqual(model.entities.count, before)
    }

    func testAddManualEntityNotFoundReturnsZero() {
        let model = makeModel(text: "Nothing matches here.")
        XCTAssertEqual(model.addManualEntity(text: "Garcia", type: .person), 0)
    }
}

// MARK: - SimpleDocxWriter

final class SimpleDocxWriterTests: XCTestCase {

    func testWriteThenImportRoundTripsText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleDocxWriterTests-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = "Dear John Smith,\n\nThe amount is $1,000 & rising. <Section 1>\nRegards"
        try SimpleDocxWriter.write(text, to: url)

        let imported = try DocxImporter().importDocument(url)
        XCTAssertEqual(imported.text, text)
    }
    // MARK: - File > Open command hook (audit F2)

    @MainActor
    func testRequestOpenBumpsTheOpenToken() {
        // The keyboard path to the only recovery from a failed import. Before
        // this existed, "Choose Files" in the document pane was reachable by
        // pointer only: there was no File > Open item and no shortcut.
        let session = SessionModel(makeModel: { ReviewModel(modelPath: nil) })
        let before = session.openRequestToken

        session.requestOpen()

        XCTAssertEqual(session.openRequestToken, before + 1)
    }

}
