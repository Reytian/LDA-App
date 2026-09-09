import Foundation
import Darwin

public enum AIClientInstaller {
    public struct SetupError: Error, CustomStringConvertible {
        public let description: String
        init(_ message: String) { description = message }
    }

    /// Called by the exported script through the bundled CLI, without a Python prerequisite.
    public static func install(payloadBase64: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               codexHome: URL? = nil) throws -> String {
        guard payloadBase64.utf8.count <= 1_500_000, let bytes = Data(base64Encoded: payloadBase64) else {
            throw SetupError("Invalid LDA setup payload.")
        }
        let payload = try JSONDecoder().decode(AIClientSetup.SetupPayload.self, from: bytes)
        let setup = payload.setup
        let fm = FileManager.default
        guard setup.helperPath.hasPrefix("/"), fm.isExecutableFile(atPath: setup.helperPath) else {
            throw SetupError("LDA helper missing. Keep LDA.app in its final location and export setup again.")
        }
        let target: URL
        let skillDirectory: URL?
        switch setup.client {
        case .codex:
            target = (codexHome ?? home.appendingPathComponent(".codex")).appendingPathComponent("config.toml")
            skillDirectory = home.appendingPathComponent(".agents/skills/lda")
        case .claudeCode:
            target = home.appendingPathComponent(".claude.json")
            skillDirectory = home.appendingPathComponent(".claude/skills/lda")
        case .claudeDesktop:
            target = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            skillDirectory = nil
        case .other:
            throw SetupError("Copy the supplied STDIO configuration into your AI app.")
        }
        try rejectLinks(target)
        let previous = try contentsIfPresent(target)
        let configuration = try setup.configuration()
        let updated: String
        if setup.client == .codex {
            try checkCodexConfiguration(previous ?? "")
            updated = (previous ?? "").trimmingCharacters(in: .newlines) + "\n\n" + configuration
        } else {
            let value = try previous.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [:]
            guard var object = value as? [String: Any], object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else {
                throw SetupError("Existing client settings could not be safely merged; no settings were changed.")
            }
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            guard servers["lda"] == nil else { throw SetupError("An existing LDA server was preserved. Update it in your AI app settings.") }
            let addition = try JSONSerialization.jsonObject(with: Data(configuration.utf8)) as! [String: Any]
            servers.merge(addition["mcpServers"] as! [String: Any]) { existing, _ in existing }
            object["mcpServers"] = servers
            updated = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
        }
        let skillExists = skillDirectory.map { fm.fileExists(atPath: $0.path) || isLinked($0) } ?? false
        if let skillDirectory, !skillExists { try rejectLinks(skillDirectory) }
        try save(updated, to: target, previous: previous)
        var result = "LDA MCP configuration saved. Existing settings were preserved and backed up."
        if let skillDirectory {
            if skillExists { result += "\nAn existing LDA skill was preserved. Use the exported workflow to update it manually." }
            else {
                do {
                    try save(payload.skill, to: skillDirectory.appendingPathComponent("SKILL.md"), previous: nil)
                    try save("interface:\n  display_name: \"LDA\"\n  short_description: \"Work with documents through local redaction\"\n  default_prompt: \"Use $lda with my LDA workspace and document instruction.\"\n",
                             to: skillDirectory.appendingPathComponent("agents/openai.yaml"), previous: nil)
                }
                catch { throw SetupError("MCP settings were saved, but the LDA skill could not be installed. Save the skill from LDA Settings and install it manually.") }
                result += "\nLDA skill installed. Select LDA from the slash-command menu, then a quoted workspace name and your instruction."
            }
        }
        return result + "\nRestart your AI app. Check its MCP status, then ask LDA to attest."
    }

    /// Accept conventional MCP table headers only. Ambiguous TOML forms require manual setup.
    /// This avoids modifying a client configuration without a full TOML parser.
    static func checkCodexConfiguration(_ text: String) throws {
        let header = try NSRegularExpression(pattern: #"^\[mcp_servers\.([A-Za-z0-9_-]+)(?:\.[A-Za-z0-9_.-]+)?\]\s*(?:#.*)?$"#)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            // Refuse multiline strings and escaped spellings that could conceal an MCP table.
            if line.contains("\"\"\"") || line.contains("'''") || line.contains("\\u") || line.contains("\\U") {
                throw SetupError("This Codex configuration needs manual setup. Existing settings were preserved; copy the LDA configuration into Codex MCP Settings.")
            }
            guard line.contains("mcp_servers") else { continue }
            let source = line as NSString
            guard let match = header.firstMatch(in: line, range: NSRange(location: 0, length: source.length)),
                  source.substring(with: match.range(at: 1)) != "lda" else {
                throw SetupError("An existing or nonstandard MCP configuration was preserved. Add or update LDA in Codex MCP Settings using the exported configuration.")
            }
        }
    }

    private static func contentsIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let bytes = FileManager.default.contents(atPath: url.path), let text = String(data: bytes, encoding: .utf8) else {
            throw SetupError("Existing settings could not be read; no settings were changed.")
        }
        return text
    }

    private static func rejectLinks(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            // macOS owns these standard aliases; temporary test/client homes can traverse them.
            let systemAlias = ["/var", "/tmp"].contains(current.path)
            if !systemAlias && isLinked(current) {
                throw SetupError("A linked configuration or skill was preserved. Update it at its original location.")
            }
            current.deleteLastPathComponent()
        }
    }

    private static func isLinked(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    private static func save(_ text: String, to target: URL, previous: String?) throws {
        try rejectLinks(target)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let previous {
            let backup = target.appendingPathExtension("lda-backup-" + UUID().uuidString)
            try writePrivate(previous, to: backup)
        }
        // Detect concurrent edits rather than silently replacing them.
        guard try contentsIfPresent(target) == previous else { throw SetupError("Settings changed during setup. They were preserved; please try again.") }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".lda-setup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try writePrivate(text, to: temporary)
        guard rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func writePrivate(_ text: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: Data(text.utf8))
        try file.synchronize()
        try file.close()
    }
}
