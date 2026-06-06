//
//  CLI.swift
//  LDACLI
//
//  The command-line edge over LDAService. This is the layer that supplies the
//  ISO-8601 timestamp (LDAService stays clock-free) and translates flags into
//  facade calls.
//
//  The command tree is a root "lda" command with three subcommands:
//    - anonymize: redact a document and write the encrypted mapping sidecar.
//    - restore:   re-identify an edited redacted document via its mapping.
//    - detect:    print detected entities without writing anything.
//
//  Each subcommand body is a thin wrapper over a static, injectable helper
//  (runAnonymize / runRestore / runDetect) so the core logic is unit-testable on
//  temp fixtures without spawning a process or capturing stdout. The ISO-8601
//  stamp is injected via a closure that defaults to ISO8601DateFormatter, which
//  keeps tests deterministic.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ArgumentParser
import LDACore

// MARK: - Timestamp injection

/// A closure that yields an ISO-8601 timestamp string. Production passes the
/// real clock; tests pass a fixed string for determinism.
public typealias TimestampProvider = () -> String

/// The default ISO-8601 timestamp provider, backed by ISO8601DateFormatter over
/// the current Date.
public let defaultTimestampProvider: TimestampProvider = {
    ISO8601DateFormatter().string(from: Date())
}

// MARK: - CLI errors

/// Errors raised at the CLI edge while validating inputs before handing off to
/// LDAService. LDAService and DocumentIO errors are surfaced separately.
public enum CLIError: Error, CustomStringConvertible {
    /// The input file does not exist at the given path.
    case inputNotFound(String)

    public var description: String {
        switch self {
        case .inputNotFound(let path):
            return "Input file not found at \(path)"
        }
    }
}

// MARK: - JSON summaries

/// A detected entity, shaped for the detect subcommand's JSON output. Mirrors the
/// public Span fields the CLI contract exposes.
public struct DetectedEntityJSON: Codable, Equatable {
    public let type: String
    public let text: String
    public let start: Int
    public let end: Int
    public let source: String
    public let confidence: Double

    public init(span: Span) {
        self.type = span.type.rawValue
        self.text = span.text
        self.start = span.start
        self.end = span.end
        self.source = span.source.rawValue
        self.confidence = span.confidence
    }
}

/// The JSON summary printed by the anonymize subcommand.
public struct AnonymizeSummaryJSON: Codable, Equatable {
    public let redactedFileURL: String
    public let mappingFileURL: String
    public let visualPdfURL: String?
    public let entityCount: Int

    public init(result: AnonymizeResult) {
        self.redactedFileURL = result.redactedFileURL.path
        self.mappingFileURL = result.mappingFileURL.path
        self.visualPdfURL = result.visualPdfURL?.path
        self.entityCount = result.entityCount
    }
}

/// The JSON summary printed by the restore subcommand.
public struct RestoreSummaryJSON: Codable, Equatable {
    public let outputURL: String
    public let restoredCount: Int
    public let orphanTokens: [String]

    public init(report: RestoreReport) {
        self.outputURL = report.outputURL.path
        self.restoredCount = report.restoredCount
        self.orphanTokens = report.orphanTokens
    }
}

// MARK: - CLI entry surface

/// The CLI entry surface. main() runs the root command tree.
public enum LDACLI {
    /// Program entry point. Parses argv and dispatches to the matching
    /// subcommand, mapping any error to stderr plus a nonzero exit code.
    public static func main() {
        LDARoot.main()
    }

    // MARK: Testable helpers

    /// Anonymize core: validate the input exists, derive a Keychain account from
    /// the output base name when no passphrase is given, stamp the timestamp via
    /// the injected provider, and run LDAService.anonymize.
    public static func runAnonymize(
        input: URL,
        outputDir: URL,
        passphrase: String?,
        timestamp: TimestampProvider = defaultTimestampProvider
    ) throws -> AnonymizeResult {
        try requireExists(input)
        let protection = protectionFor(
            passphrase: passphrase,
            derivedAccount: input.deletingPathExtension().lastPathComponent
        )
        return try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: timestamp()
        )
    }

    /// Restore core: validate the inputs exist, derive a Keychain account from the
    /// edited redacted base name when no passphrase is given, and run
    /// LDAService.restore.
    public static func runRestore(
        input: URL,
        mapping: URL,
        output: URL,
        passphrase: String?
    ) throws -> RestoreReport {
        try requireExists(input)
        try requireExists(mapping)
        let protection = protectionFor(
            passphrase: passphrase,
            derivedAccount: input.deletingPathExtension().lastPathComponent
        )
        return try LDAService.restore(
            editedRedacted: input,
            mapping: mapping,
            protection: protection,
            output: output
        )
    }

    /// Detect core: validate the input exists and run LDAService.detect.
    public static func runDetect(input: URL) throws -> [Span] {
        try requireExists(input)
        return try LDAService.detect(input: input)
    }

    // MARK: Helper internals

    /// Throw CLIError.inputNotFound when the path does not exist on disk.
    private static func requireExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.inputNotFound(url.path)
        }
    }

    /// Choose a MappingProtection: an explicit passphrase, or a Keychain account
    /// derived from the supplied base name.
    private static func protectionFor(
        passphrase: String?,
        derivedAccount: String
    ) -> MappingProtection {
        if let passphrase, !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(account: "lda-\(derivedAccount)")
    }
}

// MARK: - JSON printing

/// Encodes a value to a single-line JSON string with sorted keys for stable,
/// parseable output. Used by every subcommand to print its summary to stdout.
enum CLIJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Command tree

/// The root "lda" command. Holds the three subcommands and prints help by
/// default when invoked with no subcommand.
struct LDARoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lda",
        abstract: "Legal Document Anonymizer.",
        subcommands: [Anonymize.self, Restore.self, Detect.self]
    )
}

/// anonymize subcommand.
struct Anonymize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Redact a document and write an encrypted mapping sidecar."
    )

    @Option(name: .long, help: "Path to the source document.")
    var input: String

    @Option(name: .long, help: "Directory to write the edit surface and sidecar.")
    var outputDir: String

    @Option(name: .long, help: "Passphrase to protect the mapping. Optional.")
    var passphrase: String?

    func run() throws {
        do {
            let result = try LDACLI.runAnonymize(
                input: URL(fileURLWithPath: input),
                outputDir: URL(fileURLWithPath: outputDir),
                passphrase: passphrase
            )
            print(try CLIJSON.encode(AnonymizeSummaryJSON(result: result)))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}

/// restore subcommand.
struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore an edited redacted document via its mapping."
    )

    @Option(name: .long, help: "Path to the edited redacted document.")
    var input: String

    @Option(name: .long, help: "Path to the .ldamap mapping sidecar.")
    var mapping: String

    @Option(name: .long, help: "Path to write the restored document.")
    var output: String

    @Option(name: .long, help: "Passphrase that protects the mapping. Optional.")
    var passphrase: String?

    func run() throws {
        do {
            let report = try LDACLI.runRestore(
                input: URL(fileURLWithPath: input),
                mapping: URL(fileURLWithPath: mapping),
                output: URL(fileURLWithPath: output),
                passphrase: passphrase
            )
            print(try CLIJSON.encode(RestoreSummaryJSON(report: report)))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}

/// detect subcommand.
struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect entities in a document without writing anything."
    )

    @Option(name: .long, help: "Path to the source document.")
    var input: String

    func run() throws {
        do {
            let spans = try LDACLI.runDetect(input: URL(fileURLWithPath: input))
            let entities = spans.map(DetectedEntityJSON.init)
            print(try CLIJSON.encode(entities))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}

// MARK: - Runtime error mapping

/// Wraps any LDAService / DocumentIO / CLI error in an ArgumentParser-friendly
/// error so ArgumentParser prints a clear stderr message and exits nonzero. The
/// message is human-readable rather than the raw enum description.
struct CLIRuntimeError: Error, CustomStringConvertible {
    let underlying: Error

    init(_ underlying: Error) {
        self.underlying = underlying
    }

    var description: String {
        message(for: underlying)
    }

    private func message(for error: Error) -> String {
        switch error {
        case let cliError as CLIError:
            return cliError.description
        case DocumentIOError.unreadable(let detail):
            return "Could not read the document: \(detail)"
        case DocumentIOError.unsupportedFormat(let detail):
            return "Unsupported format: \(detail)"
        case DocumentIOError.corrupt(let detail):
            return "The document is corrupt: \(detail)"
        case DocumentIOError.ocrUnavailable:
            return "OCR is required but unavailable on this system."
        case DocumentIOError.decryptionFailed:
            return "Could not decrypt the mapping (wrong passphrase or tampered file)."
        case DocumentIOError.keychainError(let status):
            return "Keychain operation failed with status \(status)."
        default:
            return "\(error)"
        }
    }
}
