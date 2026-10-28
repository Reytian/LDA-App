//
//  MCPBatchTools.swift
//  LDAMCP
//
//  batch_anonymize: batch processing offered through MCP. The tool opens
//  LDA's Batch Anonymize window on this Mac (MCPBatchRequest) and waits for
//  the window's answer (MCPBatchReply). The person chooses the folders, the
//  output style and how mappings are sealed there; no argument can. Only the
//  outcome and counts come back: no path, file name, reason or text.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import AppKit
import LDACore

extension MCPServer {
    func callBatchAnonymize(_ arguments: [String: Any]) throws -> [String: Any] {
        guard arguments.isEmpty else { throw MCPVaultToolError.invalidBatchArguments }
        let request = MCPBatchRequest()
        let reply: MCPBatchReply?
        #if DEBUG
        if let batchAnonymizeForTesting { reply = try batchAnonymizeForTesting(request) }
        else { reply = try awaitBatchLocally(request) }
        #else
        reply = try awaitBatchLocally(request)
        #endif
        return Self.batchSummary(reply)
    }

    /// The tool result: the outcome and counts, nothing else.
    static func batchSummary(_ reply: MCPBatchReply?) -> [String: Any] {
        guard let reply, reply.outcome.isFinal else {
            return [
                "outcome": "still_open",
                "note": "The Batch Anonymize window is still open on this Mac. A batch run there writes its report to the output folder the person chose."
            ]
        }
        return [
            "outcome": reply.outcome.rawValue,
            "documentCount": reply.documentCount,
            "writtenCount": reply.writtenCount,
            "skippedCount": reply.skippedCount,
            "failedCount": reply.failedCount,
            "autoProtectedValueCount": reply.autoProtectedValueCount,
            "note": "The redacted copies, the mappings and lda-batch-report.txt stay in the output folder the person chose. Nobody reviewed these documents."
        ]
    }

    /// Opens the batch window and waits for its final answer. Returns nil
    /// when the window is still open at MCPBatchRequest.answerWindow.
    func awaitBatchLocally(_ request: MCPBatchRequest) throws -> MCPBatchReply? {
        guard Thread.isMainThread else { throw MCPVaultToolError.localHandoffUnavailable }
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { throw MCPVaultToolError.localHandoffUnavailable }
        #endif
        let appURL = environment["LDA_APP_PATH"].map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.haotianyi.LDA")
        guard let appURL else { throw MCPVaultToolError.localHandoffUnavailable }
        MCPLocalHandoff.openBatchWindow(request, appURL: appURL)
        let locations = MCPBatchBridge.replyLocations(for: request.id)
        defer { for url in locations { try? FileManager.default.removeItem(at: url) } }
        var opened = false
        while true {
            // The window must take the request while its URL is still valid.
            if !opened, request.isExpired() { throw MCPVaultToolError.batchWindowUnavailable }
            if !request.canBeAnswered() { return nil }
            for url in locations where FileManager.default.fileExists(atPath: url.path) {
                let reply = try Self.readBatchReply(at: url, for: request)
                if reply.outcome.isFinal { return reply }
                opened = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private static func readBatchReply(at url: URL, for request: MCPBatchRequest) throws -> MCPBatchReply {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) < 4096,
              let data = FileManager.default.contents(atPath: url.path),
              let reply = try? JSONDecoder().decode(MCPBatchReply.self, from: data),
              reply.requestID == request.id, reply.createdAt >= request.createdAt,
              reply.createdAt <= Date().addingTimeInterval(5) else {
            throw MCPVaultToolError.batchWindowUnavailable
        }
        return reply
    }
}
