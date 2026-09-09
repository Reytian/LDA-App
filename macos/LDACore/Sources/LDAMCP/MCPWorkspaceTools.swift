import AppKit
import LDACore

extension MCPServer {
    func callChooseWorkspace(_ arguments: [String: Any]) throws -> [String: Any] {
        guard Set(arguments.keys) == ["handle"] else { throw MCPVaultToolError.workspaceSelectionCancelled }
        let handle = try requireStringArgument(arguments, key: "handle")
        let vault = openVault()
        let entry = try vault.entry(handle: handle)
        let selection: UUID?
        #if DEBUG
        if let chooseWorkspaceForTesting {
            selection = try chooseWorkspaceForTesting(entry)
        } else {
            selection = try chooseWorkspaceLocally(entry)
        }
        #else
        selection = try chooseWorkspaceLocally(entry)
        #endif
        let updated = try vault.assignWorkspace(handle: handle, workspaceID: selection)
        var result: [String: Any] = ["handle": updated.handle, "assigned": selection != nil]
        if let selection { result["workspaceID"] = selection.uuidString.lowercased() }
        return result
    }

    func chooseWorkspaceLocally(_ entry: VaultEntry, workspaceHint: String? = nil) throws -> UUID? {
        guard Thread.isMainThread else { throw MCPVaultToolError.workspaceUnavailable }
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { throw MCPVaultToolError.workspaceUnavailable }
        #endif
        let request = MCPWorkspaceRequest(handle: entry.handle, currentWorkspaceID: entry.workspaceID, workspaceHint: workspaceHint)
        let appURL = environment["LDA_APP_PATH"].map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.haotianyi.LDA")
        guard let appURL else { throw MCPVaultToolError.workspaceUnavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([request.url], withApplicationAt: appURL, configuration: configuration)
        let locations = MCPWorkspaceBridge.replyLocations(for: request.id)
        defer { for url in locations { try? FileManager.default.removeItem(at: url) } }
        while !request.isExpired() {
            for url in locations where FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? 0) < 4096 else { throw MCPVaultToolError.workspaceUnavailable }
                guard let data = FileManager.default.contents(atPath: url.path) else { throw MCPVaultToolError.workspaceUnavailable }
                let reply = try JSONDecoder().decode(MCPWorkspaceReply.self, from: data)
                guard reply.requestID == request.id, reply.createdAt >= request.createdAt,
                      reply.createdAt <= Date().addingTimeInterval(5), reply.confirmed else {
                    throw MCPVaultToolError.workspaceSelectionCancelled
                }
                return reply.workspaceID
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw MCPVaultToolError.workspaceSelectionCancelled
    }
}
