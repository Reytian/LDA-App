import Foundation

extension DocumentVault {
    /// A separate encrypted registry holds selections until all local choices are complete.
    /// Its handles cannot be resolved by normal MCP operations on this vault.
    public func localPreparationVault() -> DocumentVault {
        DocumentVault(rootDirectory: rootDirectory.appendingPathComponent("preparation/" + UUID().uuidString), protection: protection)
    }

    /// Called only by local user interfaces after choosing an existing Matter.
    /// Derived artifacts inherit their source association when committed.
    public func assignWorkspace(handle: String, workspaceID: UUID?) throws -> VaultEntry {
        try withRegistryTransaction {
            var registry = try loadRegistryLocked()
            guard let index = registry.entries.firstIndex(where: { $0.handle == handle }) else {
                throw DocumentVaultError.unknownHandle(handle)
            }
            registry.entries[index].workspaceID = workspaceID
            registry.entries[index].workspaceSelectionIsExplicit = true
            try saveRegistryLocked(registry)
            return registry.entries[index]
        }
    }

    /// The registry anchors journal identity independently of its record/key/checkpoint files.
    func auditIdentity() throws -> UUID? {
        try withRegistryTransaction { try loadRegistryLocked().mcpAuditJournalID }
    }

    func installAuditIdentity(_ id: UUID) throws {
        try withRegistryTransaction {
            var registry = try loadRegistryLocked()
            guard registry.mcpAuditJournalID == nil || registry.mcpAuditJournalID == id else {
                throw MCPAuditError.integrityFailure
            }
            registry.mcpAuditJournalID = id
            try saveRegistryLocked(registry)
        }
    }
}
