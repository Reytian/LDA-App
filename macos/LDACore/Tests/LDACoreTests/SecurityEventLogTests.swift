//
//  SecurityEventLogTests.swift
//  LDACoreTests
//
//  The encrypted audit trail: disabled by default, records what it should,
//  records NOTHING that identifies a client or a document, bounds its own
//  size, and survives a round trip through its encrypted container.
//
//  These tests exercise the log through its public surface plus one
//  EncryptedContainer integration case, so the hook that matters (a real store
//  operation producing a real event) is covered, not just the log in isolation.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SecurityEventLogTests: XCTestCase {

    private var workDir: URL!
    private var log: SecurityEventLog { SecurityEventLog.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecurityEventLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // The log is process-wide state. Point it at a private directory and
        // start from a known-empty state for every test.
        log.isEnabled = false
        log.directory = workDir
    }

    override func tearDownWithError() throws {
        // Never leak enablement or the directory into another suite.
        log.isEnabled = false
        log.directory = SecurityEventLog.defaultDirectory()
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Default off

    func testRecordingIsOffByDefault() throws {
        // Arrange: enabled is false from setUp, mirroring a fresh process.
        // Act
        log.record(kind: .containerSealed, scope: "Test", atISO8601: "2026-08-26T00:00:00Z")
        log.flush()

        // Assert
        XCTAssertTrue(try log.readAll().isEmpty, "a disabled log must record nothing")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workDir.appendingPathComponent(SecurityEventLog.fileName).path
            ),
            "a disabled log must not create a file"
        )
    }

    // MARK: - Recording

    func testRecordsAnEnabledEvent() throws {
        log.isEnabled = true

        log.record(
            kind: .containerOpened,
            scope: "Mapping sidecar",
            subjectDigest: "abc123",
            atISO8601: "2026-08-26T10:00:00Z"
        )

        let events = try log.readAll()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .containerOpened)
        XCTAssertEqual(events[0].scope, "Mapping sidecar")
        XCTAssertEqual(events[0].subjectDigest, "abc123")
        XCTAssertTrue(events[0].succeeded)
        XCTAssertEqual(events[0].atISO8601, "2026-08-26T10:00:00Z")
    }

    func testFailureFlushesImmediately() throws {
        log.isEnabled = true

        // One failure, well below flushThreshold, must already be on disk: a
        // denied Keychain read is exactly the record a crash must not lose.
        log.record(
            kind: .keychainAccessDenied,
            scope: "Mapping sidecar",
            succeeded: false,
            detail: "OSStatus -128",
            atISO8601: "2026-08-26T10:00:01Z"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workDir.appendingPathComponent(SecurityEventLog.fileName).path
            ),
            "a failure event should be flushed at once"
        )
        XCTAssertNil(log.lastFailure, "the flush itself should have succeeded")
    }

    func testSuccessesAreBufferedUntilTheThreshold() throws {
        log.isEnabled = true
        let logFile = workDir.appendingPathComponent(SecurityEventLog.fileName)

        for index in 0 ..< (SecurityEventLog.flushThreshold - 1) {
            log.record(
                kind: .containerOpened,
                scope: "Mapping sidecar",
                atISO8601: "2026-08-26T10:00:\(String(format: "%02d", index))Z"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logFile.path),
            "successes below the threshold should stay buffered, off the hot path"
        )

        // Crossing the threshold writes through.
        log.record(kind: .containerOpened, scope: "Mapping sidecar", atISO8601: "2026-08-26T10:01:00Z")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))
        XCTAssertEqual(try log.readAll().count, SecurityEventLog.flushThreshold)
    }

    func testExplicitFlushPersistsAPartialBuffer() throws {
        log.isEnabled = true
        log.record(kind: .containerSealed, scope: "Mapping sidecar", atISO8601: "2026-08-26T11:00:00Z")
        log.flush()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workDir.appendingPathComponent(SecurityEventLog.fileName).path
            )
        )
    }

    // MARK: - Persistence

    func testEventsSurviveAReload() throws {
        log.isEnabled = true
        log.record(kind: .containerSealed, scope: "Client mapping", atISO8601: "2026-08-26T12:00:00Z")
        log.flush()

        // Re-point at the same directory, which resets the in-memory view and
        // forces a decrypt-and-decode from disk.
        log.directory = workDir
        let events = try log.readAll()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].scope, "Client mapping")
    }

    func testOnDiskLogIsEncrypted() throws {
        log.isEnabled = true
        log.record(kind: .containerSealed, scope: "Mapping sidecar", atISO8601: "2026-08-26T13:00:00Z")
        log.flush()

        let raw = try Data(contentsOf: workDir.appendingPathComponent(SecurityEventLog.fileName))
        XCTAssertFalse(
            raw.range(of: Data("Mapping sidecar".utf8)) != nil,
            "the scope must not be readable in the clear on disk"
        )
        XCTAssertTrue(
            raw.range(of: Data("LDAAUD".utf8)) != nil,
            "the log should carry its own container magic"
        )
    }

    // MARK: - Bounds

    func testTheLogIsCappedAtMaxEvents() throws {
        log.isEnabled = true
        // Overshoot the cap by a small margin; the oldest entries drop first.
        for index in 0 ..< (SecurityEventLog.maxEvents + 25) {
            log.record(
                kind: .containerOpened,
                scope: "Mapping sidecar",
                detail: "\(index)",
                atISO8601: "2026-08-26T14:00:00Z"
            )
        }
        let events = try log.readAll()
        XCTAssertEqual(events.count, SecurityEventLog.maxEvents)
        XCTAssertEqual(
            events.last?.detail, "\(SecurityEventLog.maxEvents + 24)",
            "the newest event must be retained"
        )
        XCTAssertEqual(
            events.first?.detail, "25",
            "the oldest events must be the ones dropped"
        )
    }

    func testClearRemovesTheLog() throws {
        log.isEnabled = true
        log.record(kind: .containerSealed, scope: "Mapping sidecar", atISO8601: "2026-08-26T15:00:00Z")
        log.flush()

        try log.clear()

        XCTAssertTrue(try log.readAll().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workDir.appendingPathComponent(SecurityEventLog.fileName).path
            )
        )
    }

    // MARK: - Subject digest

    func testSubjectDigestIsStableAndDoesNotContainTheAccount() {
        let account = "client-acme-holdings-litigation"
        let first = SecurityEventLog.subjectDigest(service: "svc", account: account)
        let second = SecurityEventLog.subjectDigest(service: "svc", account: account)

        XCTAssertEqual(first, second, "the digest must be stable so events correlate")
        XCTAssertFalse(
            first.contains("acme"),
            "the digest must not carry the client label it was derived from"
        )
        XCTAssertEqual(first.count, 16, "8 bytes of SHA-256, hex encoded")
        XCTAssertNotEqual(
            first,
            SecurityEventLog.subjectDigest(service: "svc", account: account + "2"),
            "different accounts must not collide"
        )
        XCTAssertNotEqual(
            first,
            SecurityEventLog.subjectDigest(service: "other", account: account),
            "the service must be part of the digest so stores stay distinct"
        )
    }

    // MARK: - Integration with EncryptedContainer

    func testAContainerSealAndOpenAreAudited() throws {
        log.isEnabled = true
        let container = EncryptedContainer(
            magic: Array("LDAAUDT".utf8),
            keychainService: "ai.openclaw.lda.audittest",
            containerDescription: "Audited test store"
        )
        let target = workDir.appendingPathComponent("audited.bin")

        try container.save(Data("payload".utf8), to: target, protection: .passphrase("pass phrase"))
        _ = try container.load(from: target, protection: .passphrase("pass phrase"))
        log.flush()

        let kinds = try log.readAll()
            .filter { $0.scope == "Audited test store" }
            .map(\.kind)
        XCTAssertTrue(kinds.contains(.containerSealed), "the seal should be recorded")
        XCTAssertTrue(kinds.contains(.containerOpened), "the open should be recorded")
    }

    func testAFailedOpenIsAudited() throws {
        log.isEnabled = true
        let container = EncryptedContainer(
            magic: Array("LDAAUDF".utf8),
            keychainService: "ai.openclaw.lda.auditfail",
            containerDescription: "Failing test store"
        )
        let target = workDir.appendingPathComponent("failing.bin")
        try container.save(Data("payload".utf8), to: target, protection: .passphrase("right one"))

        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("wrong one"))
        )
        log.flush()

        let failures = try log.readAll().filter {
            $0.scope == "Failing test store" && !$0.succeeded
        }
        XCTAssertEqual(failures.first?.kind, .containerOpenFailed)
    }

    func testTheAuditLogsOwnContainerIsNotAudited() throws {
        log.isEnabled = true
        // Recording one event flushes through the log's own container. If that
        // container were audited, the write would record another event and
        // recurse. Assert the log holds exactly what was recorded.
        log.record(kind: .containerSealed, scope: "Mapping sidecar", atISO8601: "2026-08-26T16:00:00Z")
        log.flush()

        let events = try log.readAll()
        XCTAssertEqual(events.count, 1, "the log must not audit its own writes")
        XCTAssertEqual(events[0].scope, "Mapping sidecar")
    }
}
