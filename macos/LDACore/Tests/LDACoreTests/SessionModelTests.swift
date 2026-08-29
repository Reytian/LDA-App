//
//  SessionModelTests.swift
//  LDACoreTests
//
//  Tests for the multi-document session view-model: the tray (add, remove,
//  .zip expansion), the hand-to-AI build (one shared mapping across the
//  session, client seeding, skipped-document reporting), paste-based restore,
//  and the add-a-missed-item correction on ReviewModel.
//
//  Deterministic-only (useLLM = false) so the GGUF model is never required.
//  Hermetic: fixtures under FileManager.temporaryDirectory; the client store
//  uses a temp root and passphrase protection (no Keychain access).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore
@testable import LDAUI

@MainActor
final class SessionModelTests: XCTestCase {

    private static let createdAt = "2026-06-11T00:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionModelTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A session whose models run deterministic-only and whose client store
    /// lives under the temp root with passphrase protection.
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
        // Isolate the parked-session location: restorePasted and
        // requestPasteRestore resume a parked session just in time, and the
        // default location is the REAL Application Support directory, which
        // may carry a parked mapping from the developer's own use of the app.
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        return session
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
        let defaults = UserDefaults.standard
        let priorValue = defaults.object(forKey: SessionModel.parkedClientLabelKey)
        defaults.removeObject(forKey: SessionModel.parkedClientLabelKey)
        defer {
            if let priorValue {
                defaults.set(priorValue, forKey: SessionModel.parkedClientLabelKey)
            } else {
                defaults.removeObject(forKey: SessionModel.parkedClientLabelKey)
            }
        }

        let first = makeSession()
        first.selectClient("Acme Privileged Matter")
        let doc = try write("parked.txt", "Mail john@acme.com.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        _ = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        XCTAssertNil(defaults.string(forKey: SessionModel.parkedClientLabelKey))
        let parkedBytes = try Data(contentsOf: first.parkedMappingURL())
        XCTAssertNil(
            String(data: parkedBytes, encoding: .utf8)?.range(of: "Acme Privileged Matter")
        )

        let relaunched = makeSession()
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
