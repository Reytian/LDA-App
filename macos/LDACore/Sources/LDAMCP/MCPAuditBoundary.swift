import Foundation
import LDACore

extension MCPServer {
    /// Persist the intent before dispatch, then persist the response fingerprint before release.
    /// A response record means prepared for release, not acknowledged by the remote client.
    func auditedToolCall(request: Data, params: [String: Any], dispatch: () -> Data?) throws -> Data? {
        let callID = UUID().uuidString.lowercased()
        let suppliedName = params["name"] as? String ?? ""
        let known = Set(Self.vaultToolNames).union(Self.legacyGatedToolNames).union(Self.removedToolNames)
        let operation = known.contains(suppliedName) ? suppliedName : "unknown"
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let inputHandles = auditHandles(arguments)
        try audit.append(callID: callID, sessionID: auditSessionID, phase: .request,
                         operation: operation, payload: request, documents: auditDocuments(inputHandles), outcome: .requested)
        guard let response = dispatch() else { throw MCPAuditError.unavailable }
        let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] ?? [:]
        let result = envelope["result"] as? [String: Any] ?? [:]
        var output: [String: Any] = [:]
        if let blocks = result["content"] as? [[String: Any]], let text = blocks.first?["text"] as? String {
            output = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        let refused = envelope["error"] != nil || (result["isError"] as? Bool) == true
        try audit.append(callID: callID, sessionID: auditSessionID, phase: .response,
                         operation: operation, payload: response,
                         documents: auditDocuments(inputHandles.union(auditHandles(output))),
                         outcome: refused ? .refused : .succeeded,
                         localApproval: output["localApproval"] as? Bool == true)
        if !refused, operation == "read_redacted", let text = output["text"] as? String {
            let byteCount = text.utf8.count
            metrics.noteRedactedBytesReturned(byteCount)
            if output["localApproval"] as? Bool == true {
                metrics.notePartiallyRedactedBytesReturned(byteCount)
            }
        }
        return response
    }

    private func auditHandles(_ fields: [String: Any]) -> Set<String> {
        var result = Set<String>()
        for key in ["handle", "redactedHandle", "restoredHandle", "editedHandle", "editedRedactedHandle", "sourceHandle"] {
            if let handle = fields[key] as? String, MCPAuditJournal.validHandle(handle) { result.insert(handle) }
        }
        for handle in fields["handles"] as? [String] ?? [] where MCPAuditJournal.validHandle(handle) { result.insert(handle) }
        for document in fields["documents"] as? [[String: Any]] ?? [] { result.formUnion(auditHandles(document)) }
        return result
    }

    private func auditDocuments(_ handles: Set<String>) throws -> [MCPAuditDocument] {
        let vault = openVault()
        return try handles.sorted().map { handle in
            do {
                let entry = try vault.entry(handle: handle)
                return MCPAuditDocument(handle: handle, sourceHandle: entry.sourceHandle, workspaceID: entry.workspaceID)
            } catch DocumentVaultError.unknownHandle {
                return MCPAuditDocument(handle: handle)
            }
        }
    }
}
