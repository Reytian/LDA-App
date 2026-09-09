import Foundation

public enum AIClient: String, CaseIterable, Identifiable, Codable {
    case codex, claudeCode, claudeDesktop, other
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .other: return "Other AI app"
        }
    }
}

/// Generates reviewable local setup material. The app never edits another client's settings silently.
public struct AIClientSetup: Codable {
    public let client: AIClient
    public let helperPath: String
    public let appPath: String
    public let modelPath: String?

    public init(client: AIClient, helperPath: String, appPath: String, modelPath: String? = nil) {
        self.client = client
        self.helperPath = helperPath
        self.appPath = appPath
        self.modelPath = modelPath
    }

    public var environment: [String: String] {
        var result = ["LDA_APP_PATH": appPath]
        if let modelPath, !modelPath.isEmpty { result["LDA_MODEL_PATH"] = modelPath }
        return result
    }

    public func configuration() throws -> String {
        if client == .codex {
            let env = try environment.sorted { $0.key < $1.key }.map { "\($0.key) = \(try Self.json($0.value))" }.joined(separator: "\n")
            return "[mcp_servers.lda]\ncommand = \(try Self.json(helperPath))\nargs = []\ntool_timeout_sec = 1800\n\n[mcp_servers.lda.env]\n\(env)\n"
        }
        return try Self.json(["mcpServers": ["lda": ["command": helperPath, "args": [String](), "env": environment] as [String: Any]]], pretty: true) + "\n"
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func cliShortcutScript(helperPath: String) -> String {
        """
        #!/bin/zsh
        set -eu
        lda_source=\(shellQuote(helperPath))
        [[ -x "$lda_source" ]] || { print "The LDA command-line helper is missing. Keep LDA.app in its final location and export setup again."; exit 1; }
        mkdir -p "$HOME/.local/bin"
        lda_target="$HOME/.local/bin/lda"
        if [[ -e "$lda_target" || -L "$lda_target" ]]; then
          [[ -L "$lda_target" && "$(readlink "$lda_target")" == "$lda_source" ]] || { print "An existing lda command was preserved. Choose a different shortcut manually."; exit 1; }
        else
          ln -s "$lda_source" "$lda_target"
        fi
        print 'LDA CLI is ready at ~/.local/bin/lda. Add ~/.local/bin to PATH if your terminal does not already include it.'
        "$lda_target" --help
        """
    }

    /// The exported script backs up changed files and preserves existing server entries and skills.
    public func installationScript(skill: String) throws -> String {
        let encoded = try JSONEncoder().encode(SetupPayload(setup: self, skill: skill)).base64EncodedString()
        let cli = URL(fileURLWithPath: helperPath).deletingLastPathComponent().appendingPathComponent("lda").path
        return """
        #!/bin/zsh
        set -eu
        lda_setup_helper=\(Self.shellQuote(cli))
        [[ -x "$lda_setup_helper" ]] || { print 'The bundled LDA CLI is missing. Export setup from a complete LDA release.'; exit 1; }
        "$lda_setup_helper" setup --payload-base64 \(Self.shellQuote(encoded))
        """
    }

    struct SetupPayload: Codable {
        let setup: AIClientSetup
        let skill: String
    }

    private static func json(_ object: Any, pretty: Bool = false) throws -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
    }
}
