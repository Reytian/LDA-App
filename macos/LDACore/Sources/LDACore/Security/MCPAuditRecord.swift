import Foundation

public enum MCPAuditPhase: String, Codable, Sendable { case request, response }
public enum MCPAuditOutcome: String, Codable, Sendable { case requested, succeeded, refused }

/// Only opaque identifiers belong here. Human labels and document text never enter the journal.
public struct MCPAuditDocument: Codable, Equatable, Sendable {
    public let handle: String
    public let sourceHandle: String?
    public let workspaceID: UUID?

    public init(handle: String, sourceHandle: String? = nil, workspaceID: UUID? = nil) {
        self.handle = handle
        self.sourceHandle = sourceHandle
        self.workspaceID = workspaceID
    }
}

public struct MCPAuditEvent: Codable, Equatable, Sendable {
    public let sequence: Int
    public let callID: String
    public let sessionID: String
    public let timestamp: String
    public let phase: MCPAuditPhase
    public let operation: String
    public let payloadFingerprint: String
    public let payloadByteCount: Int
    public let documents: [MCPAuditDocument]
    public let outcome: MCPAuditOutcome
    public let localApproval: Bool
}

public struct MCPAuditRecord: Codable, Equatable, Sendable {
    public let event: MCPAuditEvent
    public let previousDigest: String
    public let digest: String
}

/// Keep an exported checkpoint separately to detect rollback of every local journal file together.
public struct MCPAuditCheckpoint: Codable, Equatable, Sendable {
    public let journalID: UUID
    public var sequence: Int
    public let headDigest: String
}

public struct MCPAuditReport: Codable, Sendable {
    public let checkpoint: MCPAuditCheckpoint
    public let records: [MCPAuditRecord]
}

public enum MCPAuditError: Error, LocalizedError {
    case integrityFailure, unavailable, invalidMetadata

    public var errorDescription: String? {
        switch self {
        case .integrityFailure: return "The MCP audit trail failed its integrity check. No document content was released."
        case .unavailable: return "The MCP audit trail could not be saved. No document content was released."
        case .invalidMetadata: return "The MCP audit record contained unsupported metadata."
        }
    }
}
