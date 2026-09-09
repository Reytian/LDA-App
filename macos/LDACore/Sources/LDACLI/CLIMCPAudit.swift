import Foundation
import ArgumentParser
import LDACore

struct VaultAudit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit", abstract: "Verify or export the encrypted MCP audit trail.",
        subcommands: [VaultAuditVerify.self, VaultAuditExport.self])
}

private struct AuditOptions: ParsableArguments {
    @Option(name: .long, help: "Vault directory. Defaults to LDA_VAULT_DIR or the local LDA vault.")
    var vaultDir: String?
    @Option(name: .long, help: "An independently retained checkpoint JSON file to check for rollback.")
    var checkpoint: String?

    func report() throws -> MCPAuditReport {
        let root = vaultDir.map { URL(fileURLWithPath: $0) } ?? DocumentVault.rootDirectory()
        let expected = try checkpoint.map {
            guard let data = FileManager.default.contents(atPath: URL(fileURLWithPath: $0).path) else {
                throw ValidationError("The retained checkpoint could not be read.")
            }
            return try JSONDecoder().decode(MCPAuditCheckpoint.self, from: data)
        }
        return try MCPAuditJournal(vault: DocumentVault(rootDirectory: root)).verify(expectedCheckpoint: expected)
    }
}

private struct VaultAuditVerify: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Authenticate every audit record and check its chain and checkpoint.")
    @OptionGroup var options: AuditOptions

    func run() throws {
        let report = try options.report()
        print(try CLIJSON.encode(report.checkpoint))
    }
}

private struct VaultAuditExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export content-free audit records and a checkpoint for independent retention.")
    @OptionGroup var options: AuditOptions
    @Argument(help: "Destination for the JSON audit report. Must not already exist.")
    var output: String

    func run() throws {
        let report = try options.report()
        let url = URL(fileURLWithPath: output)
        let checkpointURL = url.appendingPathExtension("checkpoint.json")
        guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: checkpointURL.path) else {
            throw ValidationError("Choose an unused audit export destination.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try encoder.encode(report.checkpoint).write(to: checkpointURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
        print("Exported \(report.records.count) verified records and a checkpoint. Keep the checkpoint separately to detect complete local rollback.")
    }
}
