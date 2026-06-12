//
//  SessionRecordTests.swift
//  LDACoreTests
//
//  Tests for per-session records (R18) and the awaiting-AI parked session:
//  the record store round-trip, the session model writing a record on the
//  hand-to-AI build and appending restore events, and a relaunched session
//  resuming the parked mapping.
//
//  Hermetic: temp directories and passphrase protection throughout.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class SessionRecordStoreTests: XCTestCase {

    private var root: URL!
    private var store: SessionRecordStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRecordStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try SessionRecordStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecord(createdAt: String = "2026-06-11T00:00:00Z") -> SessionRecord {
        SessionRecord(
            createdAtISO8601: createdAt,
            clientLabel: "Acme Matter",
            documents: [
                SessionRecordDocument(name: "a.txt", entityCount: 3, entityTypes: ["EMAIL", "PERSON"])
            ],
            protectedValueCount: 3
        )
    }

    func testSaveThenLoadRoundTrips() throws {
        let record = makeRecord()
        try store.save(record, protection: .passphrase("pw"))

        let loaded = try store.load(id: record.id, protection: .passphrase("pw"))

        XCTAssertEqual(loaded, record)
    }

    func testListReturnsNewestFirst() throws {
        let older = makeRecord(createdAt: "2026-06-10T00:00:00Z")
        let newer = makeRecord(createdAt: "2026-06-12T00:00:00Z")
        try store.save(older, protection: .passphrase("pw"))
        try store.save(newer, protection: .passphrase("pw"))

        let listed = try store.list(protection: .passphrase("pw"))

        XCTAssertEqual(listed.map { $0.id }, [newer.id, older.id])
    }

    func testAppendRestoreEvent() throws {
        let record = makeRecord()
        try store.save(record, protection: .passphrase("pw"))

        let event = SessionRestoreEvent(
            atISO8601: "2026-06-11T01:00:00Z",
            restoredCount: 3,
            orphanCount: 0,
            suspectCount: 1
        )
        try store.appendRestoreEvent(to: record.id, event: event, protection: .passphrase("pw"))

        let loaded = try store.load(id: record.id, protection: .passphrase("pw"))
        XCTAssertEqual(loaded?.restoreEvents, [event])
    }

    func testDeleteRemovesRecord() throws {
        let record = makeRecord()
        try store.save(record, protection: .passphrase("pw"))
        try store.delete(id: record.id)

        XCTAssertNil(try store.load(id: record.id, protection: .passphrase("pw")))
        XCTAssertTrue(try store.list(protection: .passphrase("pw")).isEmpty)
    }
}

// MARK: - Session integration

@MainActor
final class SessionModelRecordTests: XCTestCase {

    private static let createdAt = "2026-06-11T00:00:00Z"

    private var workDir: URL!
    private var recordRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionModelRecordTests-\(UUID().uuidString)", isDirectory: true)
        recordRoot = workDir.appendingPathComponent("records")
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

    /// A hermetic session: deterministic-only models, temp client store, temp
    /// record store, temp parked file, passphrase protection everywhere.
    private func makeSession() -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let recordRoot = self.recordRoot!
        let parked = workDir.appendingPathComponent("parked.ldamap")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        session.parkedMappingURL = { parked }
        session.parkedProtection = { .passphrase("pw") }
        return session
    }

    func testHandToAIWritesSessionRecordAndRestoreAppendsEvent() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()

        let handoff = try XCTUnwrap(session.buildHandToAI(createdAtISO8601: Self.createdAt))
        let recordID = try XCTUnwrap(session.currentRecordID)

        let store = try SessionRecordStore(rootDirectory: recordRoot)
        var record = try XCTUnwrap(store.load(id: recordID, protection: .passphrase("pw")))
        XCTAssertEqual(record.documents.map { $0.name }, ["a.txt"])
        XCTAssertEqual(record.documents[0].entityCount, 1)
        XCTAssertEqual(record.documents[0].entityTypes, ["EMAIL"])
        XCTAssertEqual(record.protectedValueCount, 1)
        XCTAssertTrue(record.restoreEvents.isEmpty)
        // No sensitive value leaks into the record bytes.
        XCTAssertFalse("\(record)".contains("john@acme.com"))

        _ = try XCTUnwrap(session.restorePasted(handoff.combined))

        record = try XCTUnwrap(store.load(id: recordID, protection: .passphrase("pw")))
        XCTAssertEqual(record.restoreEvents.count, 1)
        XCTAssertEqual(record.restoreEvents[0].restoredCount, 1)
        XCTAssertEqual(record.restoreEvents[0].orphanCount, 0)
    }

    func testParkedSessionResumesAfterRelaunch() async throws {
        // Session 1: build the handoff (which parks the mapping), then "quit".
        let first = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await first.addDocuments([doc])
        await first.anonymizeAll()
        let handoff = try XCTUnwrap(first.buildHandToAI(createdAtISO8601: Self.createdAt))

        // Session 2: a fresh launch resumes the parked mapping and restores.
        let relaunched = makeSession()
        relaunched.resumeParkedSession()

        XCTAssertNotNil(relaunched.sessionMapping)
        XCTAssertNotNil(relaunched.sessionNote)
        let restored = try XCTUnwrap(relaunched.restorePasted(handoff.combined))
        XCTAssertEqual(restored.text, "Mail john@acme.com please.")
    }

    func testResumeParkedSessionIsANoOpWithoutParkedFile() {
        let session = makeSession()
        session.resumeParkedSession()
        XCTAssertNil(session.sessionMapping)
        XCTAssertNil(session.sessionNote)
    }
}
