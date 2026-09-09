import Foundation
import CryptoKit

/// Durable request/response records, encrypted separately and chained under a vault-specific key.
/// The checkpoint is outside the record directory so removal or rollback of the record tail is
/// detected. Whole-store rollback requires comparison with an independently retained checkpoint.
public final class MCPAuditJournal {
    private let vault: DocumentVault
    private let cacheLock = NSLock()
    private var cachedKey: (sealed: Data, secret: Secret)?
    private struct Secret: Codable { let journalID: UUID; let key: Data }
    private static let container = EncryptedContainer(
        magic: Array("LDAMCPKEY".utf8), keychainService: "ai.openclaw.lda.mcpaudit",
        containerDescription: "MCP audit key", auditing: false)
    private static let genesis = String(repeating: "0", count: 64)
    private static let operations: Set<String> = [
        "prepare_documents", "list_pending", "anonymize", "anonymize_session", "read_redacted", "detect_entities",
        "restore", "export", "attest", "choose_workspace", "extract_profile", "fill",
        "portfolio_list", "portfolio_show", "anonymize_document", "restore_document", "unknown"
    ]

    public init(vault: DocumentVault) { self.vault = vault }
    private var root: URL { vault.rootDirectory }
    private var directory: URL { root.appendingPathComponent("mcp-audit", isDirectory: true) }
    private var keyURL: URL { root.appendingPathComponent("mcp-audit-key.sealed") }
    private var checkpointURL: URL { root.appendingPathComponent("mcp-audit-checkpoint.sealed") }

    public func append(
        callID: String, sessionID: String, phase: MCPAuditPhase, operation: String,
        payload: Data, documents: [MCPAuditDocument], outcome: MCPAuditOutcome,
        localApproval: Bool = false
    ) throws {
        guard Self.operations.contains(operation), UUID(uuidString: callID) != nil, UUID(uuidString: sessionID) != nil,
              documents.allSatisfy({ Self.validHandle($0.handle) && ($0.sourceHandle.map(Self.validHandle) ?? true) }) else {
            throw MCPAuditError.invalidMetadata
        }
        try transaction {
            let secret = try loadSecret(creating: true)
            let key = SymmetricKey(data: secret.key)
            let report = try verified(secret: secret)
            let sequence = report.checkpoint.sequence + 1
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let event = MCPAuditEvent(
                sequence: sequence, callID: callID, sessionID: sessionID,
                timestamp: formatter.string(from: Date()), phase: phase, operation: operation,
                payloadFingerprint: Self.mac(payload, key: key), payloadByteCount: payload.count,
                documents: documents, outcome: outcome, localApproval: localApproval)
            let previous = report.checkpoint.headDigest
            let digest = Self.mac(try Self.encode(event) + Data(previous.utf8), key: key)
            let record = MCPAuditRecord(event: event, previousDigest: previous, digest: digest)
            let destination = recordURL(sequence)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw MCPAuditError.integrityFailure }
            try save(try Self.encode(record), to: destination, key: key, context: "record:\(sequence)")
            // A crash between these two durable writes leaves an extra record. Verification refuses
            // that incomplete state rather than guessing whether a response reached the caller.
            let next = MCPAuditCheckpoint(journalID: secret.journalID, sequence: sequence, headDigest: digest)
            try save(try Self.encode(next), to: checkpointURL, key: key, context: "checkpoint")
        }
    }

    public func verify(expectedCheckpoint: MCPAuditCheckpoint? = nil) throws -> MCPAuditReport {
        try transaction {
            let secret = try loadSecret(creating: false)
            let report = try verified(secret: secret)
            if let expected = expectedCheckpoint {
                guard expected.journalID == report.checkpoint.journalID,
                      expected.sequence >= 0, expected.sequence <= report.records.count else {
                    throw MCPAuditError.integrityFailure
                }
                let digest = expected.sequence == 0 ? Self.genesis : report.records[expected.sequence - 1].digest
                guard digest == expected.headDigest else { throw MCPAuditError.integrityFailure }
            }
            return report
        }
    }

    public static func validHandle(_ value: String) -> Bool {
        value.range(of: "^(doc|red|res)_[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            return try VaultCrossProcessLock(lockFileURL: root.appendingPathComponent("mcp-audit.lock")).withLock {
                try cacheLock.withLock(body)
            }
        } catch let error as MCPAuditError { throw error }
        catch { throw MCPAuditError.unavailable }
    }

    private func loadSecret(creating: Bool) throws -> Secret {
        let fm = FileManager.default
        let identity = try vault.auditIdentity()
        if fm.fileExists(atPath: keyURL.path) {
            try refuseSymlink(keyURL)
            let sealed = try readLocalFile(keyURL)
            if let cachedKey, cachedKey.sealed == sealed {
                guard identity == cachedKey.secret.journalID else { throw MCPAuditError.integrityFailure }
                return cachedKey.secret
            }
            let secret: Secret
            do { secret = try JSONDecoder().decode(Secret.self, from: Self.container.load(from: keyURL, protection: vault.protection)) }
            catch { throw MCPAuditError.integrityFailure }
            guard secret.key.count == 32, identity == secret.journalID else { throw MCPAuditError.integrityFailure }
            cachedKey = (sealed, secret)
            return secret
        }
        guard creating, identity == nil, cachedKey == nil, !fm.fileExists(atPath: checkpointURL.path), !fm.fileExists(atPath: directory.path) else {
            throw MCPAuditError.integrityFailure
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = SymmetricKey(size: .bits256)
        let secret = Secret(journalID: UUID(), key: key.withUnsafeBytes { Data($0) })
        try vault.installAuditIdentity(secret.journalID)
        try Self.container.save(try Self.encode(secret), to: keyURL, protection: vault.protection)
        try secureAndSync(keyURL)
        let initial = MCPAuditCheckpoint(journalID: secret.journalID, sequence: 0, headDigest: Self.genesis)
        try save(try Self.encode(initial), to: checkpointURL, key: key, context: "checkpoint")
        cachedKey = (try readLocalFile(keyURL), secret)
        return secret
    }

    private func verified(secret: Secret) throws -> MCPAuditReport {
        let key = SymmetricKey(data: secret.key)
        let checkpoint: MCPAuditCheckpoint
        do { checkpoint = try JSONDecoder().decode(MCPAuditCheckpoint.self, from: load(checkpointURL, key: key, context: "checkpoint")) }
        catch { throw MCPAuditError.integrityFailure }
        guard checkpoint.journalID == secret.journalID, checkpoint.sequence >= 0 else { throw MCPAuditError.integrityFailure }
        try refuseSymlink(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count == checkpoint.sequence else { throw MCPAuditError.integrityFailure }
        var records: [MCPAuditRecord] = []
        var previous = Self.genesis
        for sequence in 1..<(checkpoint.sequence + 1) {
            let record: MCPAuditRecord
            do { record = try JSONDecoder().decode(MCPAuditRecord.self, from: load(recordURL(sequence), key: key, context: "record:\(sequence)")) }
            catch { throw MCPAuditError.integrityFailure }
            let digest = Self.mac(try Self.encode(record.event) + Data(previous.utf8), key: key)
            guard record.event.sequence == sequence, record.previousDigest == previous, record.digest == digest else {
                throw MCPAuditError.integrityFailure
            }
            records.append(record)
            previous = record.digest
        }
        guard previous == checkpoint.headDigest else { throw MCPAuditError.integrityFailure }
        return MCPAuditReport(checkpoint: checkpoint, records: records)
    }

    private func recordURL(_ sequence: Int) -> URL {
        directory.appendingPathComponent(String(format: "%020lld.sealed", Int64(sequence)))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func mac(_ data: Data, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ data: Data, to url: URL, key: SymmetricKey, context: String) throws {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let combined = sealed.combined else { throw MCPAuditError.unavailable }
        try combined.write(to: url, options: .atomic)
        try secureAndSync(url)
    }

    private func load(_ url: URL, key: SymmetricKey, context: String) throws -> Data {
        try refuseSymlink(url)
        let box = try AES.GCM.SealedBox(combined: readLocalFile(url))
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }

    private func readLocalFile(_ url: URL) throws -> Data {
        guard url.isFileURL, let data = FileManager.default.contents(atPath: url.path) else {
            throw MCPAuditError.unavailable
        }
        return data
    }

    private func refuseSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw MCPAuditError.integrityFailure }
    }

    private func secureAndSync(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw MCPAuditError.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw MCPAuditError.unavailable }
    }
}
