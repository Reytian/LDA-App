import CryptoKit
import XCTest
@testable import LDACore

final class MCPAuditJournalTests: XCTestCase {
    private var root: URL!
    private var journal: MCPAuditJournal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        journal = MCPAuditJournal(vault: VaultTestSupport.vault(root: root))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func append(_ payload: String = "private@example.com") throws {
        try journal.append(callID: UUID().uuidString, sessionID: UUID().uuidString, phase: .request,
                           operation: "anonymize", payload: Data(payload.utf8), documents: [], outcome: .requested)
    }

    func testPersistsAcrossInstancesWithoutStoringPayload() throws {
        try append()
        let report = try MCPAuditJournal(vault: VaultTestSupport.vault(root: root)).verify()
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.checkpoint.sequence, 1)
        XCTAssertEqual(report.records.first?.event.operation, "anonymize")
        let export = try JSONEncoder().encode(report)
        XCTAssertFalse(String(decoding: export, as: UTF8.self).contains("private@example.com"))
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("mcp-audit"), includingPropertiesForKeys: nil) {
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("anonymize"))
        }
    }

    func testFingerprintsAreKeyedAndStableWithinJournal() throws {
        try append(); try append()
        let records = try journal.verify().records
        XCTAssertEqual(records[0].event.payloadFingerprint, records[1].event.payloadFingerprint)
        XCTAssertNotEqual(records[0].digest, records[1].digest)
        XCTAssertEqual(records[1].previousDigest, records[0].digest)
        XCTAssertFalse(records[0].event.timestamp.isEmpty)
    }

    func testDeletedTailIsRefusedWithoutReset() throws {
        try append(); try append()
        try FileManager.default.removeItem(at: root.appendingPathComponent("mcp-audit/00000000000000000002.sealed"))
        XCTAssertThrowsError(try journal.verify())
        XCTAssertThrowsError(try append())
    }

    func testModifiedRecordIsRefused() throws {
        try append()
        let file = root.appendingPathComponent("mcp-audit/00000000000000000001.sealed")
        var data = try Data(contentsOf: file)
        data[data.count - 1] ^= 1
        try data.write(to: file)
        XCTAssertThrowsError(try journal.verify())
    }

    func testCheckpointRollbackIsDetected() throws {
        try append()
        let checkpoint = root.appendingPathComponent("mcp-audit-checkpoint.sealed")
        let old = try Data(contentsOf: checkpoint)
        try append()
        try old.write(to: checkpoint)
        XCTAssertThrowsError(try journal.verify())
    }

    func testRetainedCheckpointDetectsWholeJournalRollback() throws {
        try append()
        let previous = try journal.verify().checkpoint
        try append()
        let newer = try journal.verify().checkpoint
        XCTAssertNoThrow(try journal.verify(expectedCheckpoint: previous))
        XCTAssertEqual(try journal.verify(expectedCheckpoint: newer).records.count, 2)
        var impossible = newer
        impossible.sequence += 1
        XCTAssertThrowsError(try journal.verify(expectedCheckpoint: impossible))
    }

    func testMissingKeyOrCheckpointDoesNotReinitialize() throws {
        try append()
        try FileManager.default.removeItem(at: root.appendingPathComponent("mcp-audit-key.sealed"))
        XCTAssertThrowsError(try journal.verify())
        XCTAssertThrowsError(try append())
    }

    func testTwoInstancesPreserveAllRecords() throws {
        let other = MCPAuditJournal(vault: VaultTestSupport.vault(root: root))
        try append("first")
        try other.append(callID: UUID().uuidString, sessionID: UUID().uuidString, phase: .response,
                         operation: "read_redacted", payload: Data("second".utf8), documents: [], outcome: .succeeded)
        XCTAssertEqual(try journal.verify().records.count, 2)
    }
    func testAllAuditFilesDeletedCannotResetRegistryIdentity() throws {
        try append()
        for name in ["mcp-audit", "mcp-audit-key.sealed", "mcp-audit-checkpoint.sealed"] {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        journal = MCPAuditJournal(vault: VaultTestSupport.vault(root: root))
        XCTAssertThrowsError(try append())
    }

    func testLegacyPlaintextCannotReplaceAuthenticatedIdentity() throws {
        try append()
        let sealed = root.appendingPathComponent("registry.sealed")
        let original = try Data(contentsOf: sealed)
        for name in ["mcp-audit", "mcp-audit-key.sealed", "mcp-audit-checkpoint.sealed"] {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        try Data(#"{"version":1,"entries":[]}"#.utf8).write(to: root.appendingPathComponent("registry.json"))
        journal = MCPAuditJournal(vault: VaultTestSupport.vault(root: root))
        XCTAssertThrowsError(try append())
        XCTAssertEqual(try Data(contentsOf: sealed), original)
    }

    func testWrongProtectionCannotReadOrAppend() throws {
        try append()
        let wrong = MCPAuditJournal(vault: DocumentVault(rootDirectory: root, protection: .passphrase("wrong")))
        XCTAssertThrowsError(try wrong.verify())
        XCTAssertThrowsError(try wrong.append(callID: UUID().uuidString, sessionID: UUID().uuidString,
                                             phase: .request, operation: "attest", payload: Data(), documents: [], outcome: .requested))
        XCTAssertEqual(try journal.verify().records.count, 1)
    }

    func testConcurrentInstancesDoNotLoseRecords() throws {
        try append()
        let completed = expectation(description: "All writers finish")
        completed.expectedFulfillmentCount = 6
        let root = self.root!
        for _ in 0..<6 {
            DispatchQueue.global().async {
                defer { completed.fulfill() }
                do {
                    let instance = MCPAuditJournal(vault: VaultTestSupport.vault(root: root))
                    try instance.append(callID: UUID().uuidString, sessionID: UUID().uuidString,
                                        phase: .request, operation: "attest", payload: Data(), documents: [], outcome: .requested)
                } catch { XCTFail("Concurrent append failed: \(error)") }
            }
        }
        wait(for: [completed], timeout: 20)
        XCTAssertEqual(try journal.verify().records.count, 7)
    }

    func testIndependentCheckpointDetectsActualOlderVaultSnapshot() throws {
        try append()
        let snapshot = root.appendingPathExtension("snapshot")
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try FileManager.default.copyItem(at: root, to: snapshot)
        try append()
        let newer = try journal.verify().checkpoint
        try FileManager.default.removeItem(at: root)
        try FileManager.default.copyItem(at: snapshot, to: root)
        let cold = MCPAuditJournal(vault: VaultTestSupport.vault(root: root))
        XCTAssertEqual(try cold.verify().records.count, 1)
        XCTAssertThrowsError(try cold.verify(expectedCheckpoint: newer))
    }

    func testRecordReorderingIsDetected() throws {
        try append(); try append()
        let first = root.appendingPathComponent("mcp-audit/00000000000000000001.sealed")
        let second = root.appendingPathComponent("mcp-audit/00000000000000000002.sealed")
        let a = try Data(contentsOf: first), b = try Data(contentsOf: second)
        try b.write(to: first); try a.write(to: second)
        XCTAssertThrowsError(try journal.verify())
    }

}
