import Foundation

/// The bridge returns opaque IDs. An optional name already supplied by the user is only
/// a local selection hint; protected Matter labels are never enumerated to the MCP host.
public struct MCPWorkspaceRequest: Identifiable, Sendable {
    public static let lifetime: TimeInterval = 120
    public let id: UUID
    public let handle: String
    public let currentWorkspaceID: UUID?
    public let workspaceHint: String?
    public let createdAt: Date

    public init(handle: String, currentWorkspaceID: UUID?, workspaceHint: String? = nil) {
        id = UUID()
        self.handle = handle
        self.currentWorkspaceID = currentWorkspaceID
        self.workspaceHint = workspaceHint
        createdAt = Date()
    }

    public init?(url: URL, now: Date = Date()) {
        guard url.scheme == "lda-mcp", url.host == "choose-workspace",
              let id = UUID(uuidString: url.lastPathComponent),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let pairs = components.queryItems ?? []
        guard Set(pairs.map(\.name)).count == pairs.count,
              Set(pairs.map(\.name)).isSubset(of: ["handle", "created", "current", "hint"]),
              url.pathComponents.count == 2, url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
        guard let handle = fields["handle"], MCPAuditJournal.validHandle(handle),
              let raw = fields["created"], let seconds = Double(raw), seconds.isFinite else { return nil }
        let created = Date(timeIntervalSince1970: seconds)
        guard now.timeIntervalSince(created) >= -5, now.timeIntervalSince(created) < Self.lifetime else { return nil }
        let current = fields["current"].flatMap(UUID.init(uuidString:))
        if fields["current"] != nil && current == nil { return nil }
        if let hint = fields["hint"], hint.isEmpty || hint.utf8.count > 256 || hint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return nil }
        workspaceHint = fields["hint"]
        self.id = id
        self.handle = handle
        currentWorkspaceID = current
        createdAt = created
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "lda-mcp"
        components.host = "choose-workspace"
        components.path = "/\(id.uuidString.lowercased())"
        components.queryItems = [URLQueryItem(name: "handle", value: handle),
                                 URLQueryItem(name: "created", value: String(createdAt.timeIntervalSince1970))]
        if let currentWorkspaceID { components.queryItems?.append(URLQueryItem(name: "current", value: currentWorkspaceID.uuidString)) }
        if let workspaceHint { components.queryItems?.append(URLQueryItem(name: "hint", value: workspaceHint)) }
        return components.url!
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) >= Self.lifetime
    }
}

public struct MCPWorkspaceReply: Codable, Sendable {
    public let requestID: UUID
    public let confirmed: Bool
    public let workspaceID: UUID?
    public let createdAt: Date

    public init(requestID: UUID, confirmed: Bool, workspaceID: UUID?) {
        self.requestID = requestID
        self.confirmed = confirmed
        self.workspaceID = workspaceID
        createdAt = Date()
    }
}

public enum MCPWorkspaceBridge {
    public static let directoryName = "MCPWorkspaceReplies"

    /// Called by the sandboxed GUI. Its application-support URL is container-scoped.
    public static func reply(_ response: MCPWorkspaceReply) throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("LDA").appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(response.requestID.uuidString.lowercased() + ".json")
        try JSONEncoder().encode(response).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The headless host can read opaque replies from either a packaged or a development GUI.
    public static func replyLocations(for requestID: UUID) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bases = [
            home.appendingPathComponent("Library/Containers/com.haotianyi.LDA/Data/Library/Application Support/LDA"),
            home.appendingPathComponent("Library/Application Support/LDA")
        ]
        return bases.map { $0.appendingPathComponent(directoryName).appendingPathComponent(requestID.uuidString.lowercased() + ".json") }
    }
}
