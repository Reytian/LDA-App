import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

/// Shared between optional onboarding and the permanent Settings entry.
public struct MCPSetupView: View {
    @State private var client = AIClient.codex
    @State private var helperOverride: URL?
    @State private var status: String?
    @State private var failed = false

    public init() {}

    private var helper: URL {
        helperOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lda-mcp")
    }
    private var plan: AIClientSetup {
        AIClientSetup(client: client, helperPath: helper.path, appPath: Bundle.main.bundleURL.path,
                      modelPath: AISettings.resolveModelPath())
    }
    private var ready: Bool { FileManager.default.isExecutableFile(atPath: helper.path) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Connect LDA to your AI app")
                .font(.system(.title2, design: .serif).weight(.semibold))
            TutorialGallery()
            L10n.text("Choose an app, save its setup script, then open the script in Terminal. Setup is optional; you can return here from Settings at any time.")
                .foregroundStyle(.secondary)
            Picker(selection: $client) {
                ForEach(AIClient.allCases) { item in
                    if item == .other { L10n.text("Other AI app").tag(item) }
                    else { Text(verbatim: item.name).tag(item) }
                }
            } label: { L10n.text("AI app") }
            if ready {
                Label { L10n.text("MCP helper is ready") } icon: { Image(systemName: "checkmark.circle") }
                    .foregroundStyle(.secondary)
            } else {
                L10n.text("This build has no bundled MCP helper. Choose lda-mcp from an LDA release package.")
                    .foregroundStyle(CounselTheme.danger)
                L10n.button("Choose MCP Helper") { chooseHelper() }
            }
            L10n.text("Keep LDA.app in its final location before setting up a connection.")
                .font(.callout).foregroundStyle(.secondary)
            if AISettings.resolveModelPath() == nil {
                L10n.text("This connection will use Patterns only. Set up a detection model in AI Settings for names, companies and addresses, then export setup again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if client == .other {
                L10n.text("In an app that supports local STDIO MCP, add a server named lda. Use the command and environment below. Merge the lda entry into existing settings instead of replacing the whole file. Browser-only apps that require an HTTP address cannot use this local server directly.")
            } else {
                L10n.text("The script adds only LDA, backs up changed settings, and preserves existing server entries and skills. If LDA is already configured, update its command and environment in your AI app using the configuration below.")
            }
            HStack {
                L10n.button("Copy Configuration") { copyConfiguration() }.disabled(!ready)
                L10n.button("Save Setup Script") { saveScript() }.disabled(!ready || client == .other)
                L10n.button("Save LDA Skill") { saveSkill() }.disabled(client == .claudeDesktop || client == .other)
            }
            DisclosureGroup {
                Text(verbatim: (try? plan.configuration()) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: { L10n.text("View Configuration") }
            Divider()
            L10n.text("After setup, restart your AI app and check its MCP status. Ask LDA to attest to confirm the connection.")
            if client == .codex || client == .claudeCode {
                Text(verbatim: "/LDA \"Workspace name\" Review these documents and summarize the risks.")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                L10n.text("Choose LDA from the slash-command menu, or use $lda in Codex. The workspace name is an LDA Matter, separate from your Codex project. Choose documents locally and turn on the optional PII review if you want to add protection.")
            } else {
                L10n.text("Ask your AI app to use LDA to prepare documents for your named workspace, then give your document instruction. Shortcut syntax depends on the app.")
            }
            L10n.text("Do not attach originals, mapping files or passwords to the AI chat. Any workspace name you type into chat is visible to that AI service.")
                .font(.callout).foregroundStyle(.secondary)
            if let status {
                Text(verbatim: status).foregroundStyle(failed ? CounselTheme.danger : CounselTheme.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseHelper() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let selected = panel.url,
              selected.lastPathComponent == "lda-mcp", FileManager.default.isExecutableFile(atPath: selected.path) else { return }
        helperOverride = selected
    }

    private func copyConfiguration() {
        do {
            let configuration = try plan.configuration()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(configuration, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
            failed = false; status = L10n.string("Configuration copied.")
        } catch { showFailure() }
    }

    private func workflow() throws -> String {
        if let url = LDAResourceBundle.resolve()?.url(forResource: "LDAWorkflow", withExtension: "md"),
           let bytes = FileManager.default.contents(atPath: url.path), let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func saveScript() {
        do {
            try IntegrationSetupFiles.save(try plan.installationScript(skill: workflow()), suggestedName: "Setup-LDA-\(client.name.replacingOccurrences(of: " ", with: "-")).command", executable: true)
            failed = false; status = L10n.string("Setup script saved. Open it locally in Terminal, then restart your AI app.")
        } catch CocoaError.userCancelled { }
        catch { showFailure() }
    }

    private func saveSkill() {
        do {
            try IntegrationSetupFiles.save(workflow(), suggestedName: "SKILL.md", executable: false)
            failed = false; status = L10n.string("Save this file inside the lda skill folder for your AI app. Preserve any existing custom skill before replacing it.")
        } catch CocoaError.userCancelled { }
        catch { showFailure() }
    }

    private func showFailure() {
        failed = true; status = L10n.string("Setup could not be saved. Choose a writable location and try again.")
    }
}

public struct CLISetupView: View {
    @State private var status: String?
    public init() {}
    private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lda") }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Use LDA from Terminal")
                .font(.system(.title2, design: .serif).weight(.semibold))
            L10n.text("The CLI runs locally and supports detection, redaction, restoration, vault staging and audit verification.")
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                L10n.button("Save CLI Setup Script") {
                    do {
                        try IntegrationSetupFiles.save(AIClientSetup.cliShortcutScript(helperPath: helper.path), suggestedName: "Setup-LDA-CLI.command", executable: true)
                        status = L10n.string("Open the saved script in Terminal. It creates ~/.local/bin/lda and preserves any existing command.")
                    } catch CocoaError.userCancelled { }
                    catch { status = L10n.string("Setup could not be saved. Choose a writable location and try again.") }
                }
                Text(verbatim: AIClientSetup.shellQuote(helper.path) + " --help")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else {
                L10n.text("This build has no bundled CLI helper. Use lda from an LDA release package.")
            }
            L10n.text("After installing the shortcut, run these commands in Terminal. If lda is not found, use ~/.local/bin/lda or add ~/.local/bin to PATH.")
            Text(verbatim: "lda --help\nlda detect --input '/path/to/document.docx'\nlda vault stage '/path/to/document.docx'\nlda vault list\nlda vault audit verify\nlda vault audit export '/path/to/unused-audit.json'")
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            L10n.text("Use lda anonymize --help and lda restore --help for redaction and restoration options. Keep mappings and passphrases local.")
            L10n.text("CLI output can include original values and filenames. Do not paste it into an AI chat when working with confidential documents. Use MCP for the protected document workflow.")
                .foregroundStyle(.secondary)
            if let status { Text(verbatim: status).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private enum IntegrationSetupFiles {
    static func save(_ text: String, suggestedName: String, executable: Bool) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { throw CocoaError(.userCancelled) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
}
