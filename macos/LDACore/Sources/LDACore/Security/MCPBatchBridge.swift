//
//  MCPBatchBridge.swift
//  LDACore
//
//  The local handoff behind the batch_anonymize MCP tool. The MCP helper
//  asks the app to open its Batch Anonymize window
//  (lda-mcp://batch-anonymize/<id>); the person chooses the folders and
//  options there; the window answers with an outcome and counts. The request
//  carries no path, file name or option, and the reply carries no path, file
//  name, reason or text, so nothing about the documents reaches the MCP host.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// A request from the MCP helper to open the batch window.
public struct MCPBatchRequest: Identifiable, Sendable, Equatable {
    /// How long the app accepts the request URL after the helper made it.
    public static let lifetime: TimeInterval = 120
    /// How long the helper waits for the batch to end. The app does not let
    /// a batch started later answer the request. Codex is set up with
    /// tool_timeout_sec = 1800 (AIClientSetup), so this stays under it.
    public static let answerWindow: TimeInterval = 1500

    public let id: UUID
    public let createdAt: Date

    public init() {
        id = UUID()
        createdAt = Date()
    }

    public init?(url: URL, now: Date = Date()) {
        guard url.scheme == "lda-mcp", url.host == "batch-anonymize",
              let id = UUID(uuidString: url.lastPathComponent),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let pairs = components.queryItems, pairs.count == 1, pairs[0].name == "created",
              let raw = pairs[0].value, let seconds = Double(raw), seconds.isFinite,
              url.pathComponents.count == 2, url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil else { return nil }
        let created = Date(timeIntervalSince1970: seconds)
        guard now.timeIntervalSince(created) >= -5, now.timeIntervalSince(created) < Self.lifetime else { return nil }
        self.id = id
        createdAt = created
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "lda-mcp"
        components.host = "batch-anonymize"
        components.path = "/\(id.uuidString.lowercased())"
        components.queryItems = [URLQueryItem(name: "created", value: String(createdAt.timeIntervalSince1970))]
        return components.url!
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) >= Self.lifetime
    }

    /// Whether a batch starting at `now` may still answer the request.
    public func canBeAnswered(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) < Self.answerWindow
    }
}

/// The batch window's answer: where the request stands, and counts.
public struct MCPBatchReply: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The window is open and waiting for the person. Not final.
        case opened
        /// Every document was processed.
        case finished
        /// The batch was stopped before every document was processed.
        case stopped
        /// The batch could not run, for example because a folder could not be read.
        case failed
        /// The window closed, or a newer request took its place, before a batch ran.
        case closed
        /// The window was already running a batch.
        case busy

        public var isFinal: Bool { self != .opened }
    }

    public let requestID: UUID
    public let outcome: Outcome
    public let documentCount: Int
    public let writtenCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let autoProtectedValueCount: Int
    public let createdAt: Date

    public init(requestID: UUID, outcome: Outcome, report: BatchReport? = nil) {
        self.requestID = requestID
        self.outcome = outcome
        documentCount = report?.items.count ?? 0
        writtenCount = report?.doneCount ?? 0
        skippedCount = report?.skippedCount ?? 0
        failedCount = report?.failedCount ?? 0
        autoProtectedValueCount = report?.autoProtectedValueCount ?? 0
        createdAt = Date()
    }
}

public enum MCPBatchBridge {
    public static let directoryName = "MCPBatchReplies"

    /// Called by the sandboxed GUI, once when the window takes the request
    /// and once when it is answered.
    public static func reply(_ response: MCPBatchReply) throws {
        try MCPWorkspaceBridge.write(
            try JSONEncoder().encode(response),
            requestID: response.requestID,
            directoryName: directoryName
        )
    }

    public static func replyLocations(for requestID: UUID) -> [URL] {
        MCPWorkspaceBridge.replyLocations(for: requestID, directoryName: directoryName)
    }
}
