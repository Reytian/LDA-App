import Foundation
import LDACore

extension MCPServer {
    /// The short-command entry point. Selection and extra protection are local human actions.
    func callPrepareDocuments(_ arguments: [String: Any]) throws -> [String: Any] {
        guard Set(arguments.keys).isSubset(of: ["workspaceName"]) else { throw MCPVaultToolError.localPreparationCancelled }
        let hint: String?
        if let supplied = arguments["workspaceName"] {
            guard let name = supplied as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 256, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw MCPVaultToolError.localPreparationCancelled
            }
            hint = name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { hint = nil }
        let selection: MCPLocalPreparation.Selection
        #if DEBUG
        if let selectDocumentsForTesting { selection = try selectDocumentsForTesting() }
        else { selection = try MCPLocalPreparation.selectDocuments() }
        #else
        selection = try MCPLocalPreparation.selectDocuments()
        #endif
        guard !selection.urls.isEmpty, selection.urls.count <= 20 else { throw MCPVaultToolError.localPreparationCancelled }
        let vault = openVault()
        let pendingVault = vault.localPreparationVault()
        defer { try? FileManager.default.removeItem(at: pendingVault.rootDirectory) }
        var entries: [VaultEntry] = []
        for url in selection.urls {
            guard url.isFileURL else { throw MCPVaultToolError.localPreparationCancelled }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            entries.append(try pendingVault.stage(fileURL: url, stagedAtISO8601: Self.iso8601Now()))
        }
        let workspace: UUID?
        #if DEBUG
        if let chooseWorkspaceForTesting { workspace = try chooseWorkspaceForTesting(entries[0]) }
        else { workspace = try chooseWorkspaceLocally(entries[0], workspaceHint: hint) }
        #else
        workspace = try chooseWorkspaceLocally(entries[0], workspaceHint: hint)
        #endif
        var redactionArguments: [String: Any] = [:]
        if let configured = environment["LDA_MODEL_PATH"], !configured.isEmpty { redactionArguments["modelPath"] = configured }
        #if DEBUG
        if let prepareMappingPassphraseForTesting { redactionArguments["passphrase"] = prepareMappingPassphraseForTesting }
        #endif
        let modelPath = try allowedModelPath(redactionArguments, key: "modelPath")
        var reviewDigests: [String: String] = [:]
        var patternsByHandle: [String: [CustomPattern]] = [:]
        if selection.review {
            for entry in entries {
                patternsByHandle[entry.handle] = try pendingVault.withPlaintextFileURL(handle: entry.handle) { input in
                    let text = try LDAService.localReviewText(input: input)
                    let spans: [Span]
                    #if DEBUG
                    if let localReviewDetectionForTesting { spans = try localReviewDetectionForTesting(text) }
                    else { spans = try LDAService.localReviewFindings(text: text, llmModelPath: modelPath) }
                    #else
                    spans = try LDAService.localReviewFindings(text: text, llmModelPath: modelPath)
                    #endif
                    reviewDigests[entry.handle] = AdditionalProtection.textDigest(text)
                    let added: [CustomPattern]
                    #if DEBUG
                    if let reviewDocumentForTesting { added = try reviewDocumentForTesting(text, spans) }
                    else { added = try MCPLocalPreparation.review(text: text, spans: spans) }
                    #else
                    added = try MCPLocalPreparation.review(text: text, spans: spans)
                    #endif
                    // Freeze every highlighted finding, even if a later model pass varies.
                    return spans.map { CustomPattern(text: $0.text, type: $0.type) } + added
                }
            }
        }
        var documents: [[String: Any]] = []
        for entry in entries {
            let published = try pendingVault.withPlaintextFileURL(handle: entry.handle) { input in
                try vault.stage(fileURL: input, stagedAtISO8601: Self.iso8601Now(),
                                originalFilename: entry.originalFilename, workspaceID: workspace, workspaceSelectionIsExplicit: true,
                                requiredLocalPatterns: patternsByHandle[entry.handle] ?? [], localReviewTextDigest: reviewDigests[entry.handle])
            }
            var args = redactionArguments
            args["handle"] = published.handle
            let result = try callAnonymizeHandle(args)
            var summary = result
            summary["sourceHandle"] = published.handle
            summary["localReviewCompleted"] = selection.review
            if let workspace { summary["workspaceID"] = workspace.uuidString.lowercased() }
            documents.append(summary)
        }
        return ["documents": documents, "documentCount": documents.count,
                "detectionMode": modelPath == nil ? "patterns_only" : "local_model",
                "localReviewCompleted": selection.review]
    }
}
