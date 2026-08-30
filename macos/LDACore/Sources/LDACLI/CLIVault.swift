//
//  CLIVault.swift
//  LDACLI
//
//  The human intake path for the staging vault: `lda vault stage <path>`
//  copies a document into the vault and prints its opaque handle, and
//  `lda vault list` shows what is staged. This is the counterpart of the
//  handle-first MCP surface: an agent host never sees a path, because the
//  HUMAN put the document into the vault here and the tools work on handles.
//
//  The CLI is a human-facing edge, so unlike the MCP tools it may print the
//  original filename: without it a human cannot tell which handle is which
//  document. That correlation deliberately stays on this side of the context
//  boundary.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ArgumentParser
import LDACore

// MARK: - JSON summaries

/// One vault entry, shaped for the vault subcommands' JSON output.
public struct VaultEntryJSON: Codable, Equatable {
    public let handle: String
    public let kind: String
    public let format: String
    public let byteCount: Int
    public let pageCount: Int?
    public let stagedAt: String
    /// Human-facing correlation: present for staged originals.
    public let originalFilename: String?
    /// For derived artifacts: the handle they were produced from.
    public let sourceHandle: String?

    public init(entry: VaultEntry) {
        self.handle = entry.handle
        self.kind = entry.kind.rawValue
        self.format = entry.format
        self.byteCount = entry.byteCount
        self.pageCount = entry.pageCount
        self.stagedAt = entry.stagedAtISO8601
        self.originalFilename = entry.originalFilename
        self.sourceHandle = entry.sourceHandle
    }
}

// MARK: - Testable helpers

extension LDACLI {

    /// Stage core: validate each input exists, expand any .zip into its
    /// contained documents, copy everything into the vault (encrypted at
    /// rest), and return the new entries. Expansion scratch space is cleaned
    /// up before returning (the vault holds its own copies by then).
    ///
    /// protection selects how the vault master key is held; the default
    /// resolves LDA_VAULT_PASSPHRASE from the process environment, else the
    /// Keychain master key. Tests inject a passphrase.
    public static func runVaultStage(
        inputs: [URL],
        vaultRoot: URL,
        timestamp: TimestampProvider = defaultTimestampProvider,
        protection: MappingProtection = DocumentVault.defaultProtection()
    ) throws -> [VaultEntryJSON] {
        defer { ZipImporter.cleanUpAllExpansions() }
        let resolved = try resolveSessionInputs(inputs)
        let vault = DocumentVault(rootDirectory: vaultRoot, protection: protection)
        return try resolved.map { url in
            VaultEntryJSON(entry: try vault.stage(fileURL: url, stagedAtISO8601: timestamp()))
        }
    }

    /// List core: every vault entry, oldest first.
    public static func runVaultList(
        vaultRoot: URL,
        protection: MappingProtection = DocumentVault.defaultProtection()
    ) throws -> [VaultEntryJSON] {
        try DocumentVault(rootDirectory: vaultRoot, protection: protection)
            .list()
            .map(VaultEntryJSON.init)
    }
}

// MARK: - Command tree

/// vault subcommand group.
struct Vault: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Stage documents into the local vault and inspect its contents.",
        subcommands: [
            VaultStage.self,
            VaultList.self
        ]
    )
}

/// vault stage subcommand.
struct VaultStage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stage",
        abstract: "Copy a document into the vault and print its opaque handle. "
            + "A .zip stages each contained document."
    )

    @Argument(help: "Path to the document to stage (DOCX, PDF, TXT, MD, an evidence image PNG/JPG/JPEG, or a .zip of them).")
    var path: String

    @Option(name: .long, help: "Vault directory. Defaults to LDA_VAULT_DIR when set, else Application Support/LDA/Vault.")
    var vaultDir: String?

    func run() throws {
        do {
            let root = vaultDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? DocumentVault.rootDirectory()
            let entries = try LDACLI.runVaultStage(
                inputs: [URL(fileURLWithPath: path)],
                vaultRoot: root
            )
            print(try CLIJSON.encode(entries))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}

/// vault list subcommand.
struct VaultList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the vault's staged documents and derived artifacts."
    )

    @Option(name: .long, help: "Vault directory. Defaults to LDA_VAULT_DIR when set, else Application Support/LDA/Vault.")
    var vaultDir: String?

    func run() throws {
        do {
            let root = vaultDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? DocumentVault.rootDirectory()
            print(try CLIJSON.encode(LDACLI.runVaultList(vaultRoot: root)))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}
