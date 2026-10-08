import Foundation

/// Local-only receipt. Never serialize this type into an MCP response: the URL,
/// bookmark and optional Matter label are private, even for a redacted artifact.
public struct ExportReceipt: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case app, mcp }
    public let id: UUID
    public let createdAt: Date
    public let origin: Origin
    public let format: String
    public let kind: VaultArtifactKind
    public let workspaceID: UUID?
    public let matterLabel: String?
    public let artifactHandle: String?
    public let fileURL: URL
    public let bookmark: Data?

    public init(fileURL: URL, origin: Origin, kind: VaultArtifactKind,
                workspaceID: UUID? = nil, matterLabel: String? = nil,
                artifactHandle: String? = nil, createdAt: Date = Date()) {
        id = UUID()
        self.createdAt = createdAt
        self.origin = origin
        format = DocumentVault.normalizedFormat(forExtension: fileURL.pathExtension)
        self.kind = kind
        self.workspaceID = workspaceID
        self.matterLabel = matterLabel
        self.artifactHandle = artifactHandle
        self.fileURL = fileURL
        bookmark = try? fileURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public var exportID: String { "exp_" + id.uuidString.lowercased() }
    public var localActionURL: URL { URL(string: "lda-mcp://show-export/" + id.uuidString.lowercased())! }

    public static func requestedID(from url: URL) -> UUID? {
        guard url.scheme == "lda-mcp", url.host == "show-export", url.pathComponents.count == 2,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Resolve only on a local user action, never while preparing tool metadata.
    public func resolvedURL() -> URL {
        guard let bookmark else { return fileURL }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? fileURL
    }
}

/// One encrypted, immutable file per export avoids a shared read/modify/write
/// index. Independent GUI and MCP writers cannot discard each other's history.
public struct ExportHistory {
    public let directory: URL
    private let protection: MappingProtection?
    private static let localAccount = "export-history-receipts"
    private static let container = EncryptedContainer(magic: Array("LDAEXPT".utf8),
        keychainService: "ai.openclaw.lda.exporthistory", containerDescription: "Export history")

    public init(directory: URL = ExportHistory.sharedDirectory(),
                protection: MappingProtection? = nil) {
        self.directory = directory
        self.protection = protection
    }

    /// The headless companion may write inside the installed GUI's container;
    /// the sandboxed GUI only uses its own Application Support directory.
    /// No entitlement expansion or model-supplied filesystem location is needed.
    public static func sharedDirectory() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if support.path.contains("/Library/Containers/") {
            return support.appendingPathComponent("LDA/ExportHistory")
        }
        let container = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.haotianyi.LDA/Data/Library/Application Support")
        let base = fm.fileExists(atPath: container.path) ? container : support
        return base.appendingPathComponent("LDA/ExportHistory")
    }

    public func record(_ receipt: ExportReceipt) throws {
        guard directory.isFileURL, receipt.fileURL.isFileURL else { throw DocumentVaultError.sourceUnreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The dedicated metadata key uses the existing login-keychain local
        // vault, readable by GUI and headless companions. Do not use the mapping
        // container's Touch ID migration policy here: it makes shared receipts
        // unreadable by MCP. Originals, mappings and document text are absent.
        // Lock only to serialize first-use key creation across both processes.
        try VaultCrossProcessLock(lockFileURL: directory.appendingPathComponent("history.lock")).withLock {
            let url = directory.appendingPathComponent(receipt.exportID + ".sealed")
            let data = try JSONEncoder().encode(receipt)
            if let protection { try Self.container.save(data, to: url, protection: protection) }
            else { try LocalDataVault.seal(data, account: Self.localAccount).write(to: url, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func list() throws -> [ExportReceipt] {
        guard directory.isFileURL else { throw DocumentVaultError.sourceUnreadable }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sealed" }
            .map { url in
                guard url.isFileURL else { throw DocumentVaultError.sourceUnreadable }
                let data: Data
                if let protection { data = try Self.container.load(from: url, protection: protection) }
                else {
                    guard let sealed = FileManager.default.contents(atPath: url.path) else {
                        throw DocumentVaultError.sourceUnreadable
                    }
                    data = try LocalDataVault.open(sealed, account: Self.localAccount)
                }
                return try JSONDecoder().decode(ExportReceipt.self, from: data)
            }
            .sorted { $0.createdAt == $1.createdAt ? $0.exportID > $1.exportID : $0.createdAt > $1.createdAt }
    }
}
