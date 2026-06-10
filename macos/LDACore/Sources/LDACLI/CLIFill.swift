//
//  CLIFill.swift
//  LDACLI
//
//  CLI subcommands for the fill-from-profile feature: extract-profile and fill.
//  Factored into a sibling file to keep CLI.swift under the 800-line budget.
//
//  The command tree additions:
//    - extract-profile: run extractProfile, save via ProfileStore, print a
//      value-free summary JSON (field count, raw keys, conflicts, incomplete
//      flag, failed sources, saved path).
//    - fill --plan:  load a profile, run planFill, print the plan JSON to
//      stdout. Values appear here only, for human review; nothing is persisted.
//    - fill --apply: load a profile, run planFill, promote .proposed with a
//      value to .confirmed, run applyFill, print the value-free FillReport JSON.
//
//  Testable static helpers: LDACLI.runExtractProfile, runFillPlan, runFillApply.
//  ParsableCommand structs: ExtractProfile, Fill.
//  Both are registered in LDARoot.configuration.subcommands via the array in
//  LDARoot (defined in CLI.swift); they are registered there to keep the
//  command tree in one place.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ArgumentParser
import LDACore

// MARK: - Serializable summary structs

/// Represents one failed profile source for the extract-profile JSON summary.
/// Bridges the labeled-tuple `(name:reason:)` which is not directly Codable.
public struct FailedSourceJSON: Codable, Equatable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// The value-free JSON summary printed by extract-profile. Field VALUES are
/// never included; only keys and metadata are exposed.
public struct ExtractProfileSummaryJSON: Codable, Equatable {
    public let fieldCount: Int
    /// Raw key strings in the order the fields appear in the profile.
    public let keys: [String]
    /// Raw keys of single-valued keys that currently hold more than one distinct
    /// normalized value.
    public let conflictedKeys: [String]
    /// True when any extraction segment was truncated.
    public let incomplete: Bool
    /// Sources that could not be imported.
    public let failedSources: [FailedSourceJSON]
    /// Absolute path where the encrypted .ldaprofile was saved.
    public let profilePath: String

    public init(result: ExtractProfileResult, profilePath: URL) {
        self.fieldCount = result.profile.fields.count
        self.keys = result.profile.fields.map { $0.key.rawKey }
        self.conflictedKeys = result.profile.conflictedKeys.map { $0.rawKey }
        self.incomplete = result.profile.incomplete
        self.failedSources = result.failedSources.map {
            FailedSourceJSON(name: $0.name, reason: $0.reason)
        }
        self.profilePath = profilePath.path
    }
}

/// One blank in the fill-plan JSON. Values appear here (stdout only) for human
/// review; they are never persisted by the CLI.
public struct FillPlanEntryJSON: Codable, Equatable {
    /// The blank's label (bracket contents, AcroForm field name, or empty for
    /// bare placeholder).
    public let label: String
    /// Human-readable location: "field <name>" or "offset <start>-<end>".
    public let locationDescription: String
    /// The BlankStatus raw value ("proposed", "unmatched", etc.).
    public let status: String
    /// The rawKey of the matched ProfileField, or null when unmatched or
    /// ambiguous.
    public let proposedFieldKey: String?
    /// The proposed fill value, or null when unmatched or ambiguous.
    public let proposedValue: String?
    /// Present ONLY for ambiguous blanks (proposed with nil proposedFieldID):
    /// rawKeys of every candidate profile field. Omitted otherwise to keep the
    /// JSON compact.
    public let candidates: [String]?

    public init(blank: Blank, profile: CompanyProfile) {
        self.label = blank.label
        self.locationDescription = FillPlanEntryJSON.locationDesc(blank.location)
        self.status = blank.status.rawValue
        self.proposedValue = blank.proposedValue

        // Resolve proposedFieldKey from proposedFieldID when present.
        if let fieldID = blank.proposedFieldID,
           let field = profile.fields.first(where: { $0.id == fieldID }) {
            self.proposedFieldKey = field.key.rawKey
        } else {
            self.proposedFieldKey = nil
        }

        // candidates: present only for ambiguous blanks (.proposed with nil
        // proposedFieldID but non-nil candidateFieldIDs set by FillPlanner).
        if blank.status == .proposed,
           blank.proposedFieldID == nil,
           let candidateIDs = blank.candidateFieldIDs,
           !candidateIDs.isEmpty {
            self.candidates = candidateIDs.compactMap { cid in
                profile.fields.first(where: { $0.id == cid })?.key.rawKey
            }
        } else {
            self.candidates = nil
        }
    }

    private static func locationDesc(_ location: BlankLocation) -> String {
        switch location {
        case .acroFormField(let name):
            return "field \(name)"
        case .textSpan(let start, let end):
            return "offset \(start)-\(end)"
        }
    }
}

/// Value-free fill report JSON printed by fill --apply.
public struct FillReportJSON: Codable, Equatable {
    public let outputURL: String
    public let filledCount: Int
    public let skipped: [SkippedBlankJSON]

    public init(report: FillReport) {
        self.outputURL = report.outputURL.path
        self.filledCount = report.filledCount
        self.skipped = report.skipped.map(SkippedBlankJSON.init)
    }
}

/// One skipped blank in the apply report, value-free.
public struct SkippedBlankJSON: Codable, Equatable {
    public let label: String
    public let locationDescription: String
    public let reason: String

    public init(_ skipped: SkippedBlank) {
        self.label = skipped.label
        self.locationDescription = skipped.locationDescription
        self.reason = skipped.reason
    }
}

// MARK: - LDACLI helpers

extension LDACLI {

    // MARK: runExtractProfile

    /// Extract a CompanyProfile from source documents, save it via ProfileStore,
    /// and return the value-free summary.
    ///
    /// Source existence is NOT pre-validated here: extractProfile collects
    /// unreadable sources in failedSources rather than aborting. The caller
    /// (ExtractProfile.validate) enforces a non-empty source list; individual
    /// missing files are surfaced via summary.failedSources. This mirrors the
    /// service contract in LDAFillService.extractProfile.
    ///
    /// - Parameters:
    ///   - sources: source document paths (one or more).
    ///   - label: human label for the resulting profile.
    ///   - out: destination path for the encrypted .ldaprofile.
    ///   - passphrase: explicit passphrase, or nil to use Keychain (account
    ///     derived from the output file's base name).
    ///   - llmModelPath: REQUIRED by extractProfile; see LDAFillService.
    ///   - timestamp: ISO-8601 timestamp provider (injected for testing).
    /// - Returns: (summary, profileURL) for printing and verification.
    public static func runExtractProfile(
        sources: [URL],
        label: String,
        out: URL,
        passphrase: String?,
        llmModelPath: String,
        timestamp: TimestampProvider = defaultTimestampProvider
    ) throws -> (summary: ExtractProfileSummaryJSON, profileURL: URL) {
        let result = try LDAService.extractProfile(
            sources: sources,
            label: label,
            modelPath: llmModelPath,
            createdAtISO8601: timestamp()
        )
        let protection = protectionFor(
            passphrase: passphrase,
            derivedAccount: out.deletingPathExtension().lastPathComponent
        )
        try ProfileStore.save(result.profile, to: out, protection: protection)
        let summary = ExtractProfileSummaryJSON(result: result, profilePath: out)
        return (summary, out)
    }

    // MARK: runFillPlan

    /// Load a profile, run planFill on the target, and return the plan entries.
    /// Values appear in the returned array for human review; they are printed to
    /// stdout and are NOT persisted.
    public static func runFillPlan(
        profile profileURL: URL,
        passphrase: String?,
        input: URL,
        llmModelPath: String? = nil
    ) throws -> [FillPlanEntryJSON] {
        try requireExists(profileURL)
        try requireExists(input)
        let protection = protectionFor(
            passphrase: passphrase,
            derivedAccount: profileURL.deletingPathExtension().lastPathComponent
        )
        let profile = try ProfileStore.load(from: profileURL, protection: protection)
        let plan = try LDAService.planFill(
            target: input,
            profile: profile,
            modelPath: llmModelPath
        )
        return plan.blanks.map { FillPlanEntryJSON(blank: $0, profile: profile) }
    }

    // MARK: runFillApply

    /// Load a profile, plan the fill, promote all proposed-with-value blanks to
    /// .confirmed, apply the fill, and return the value-free FillReport.
    public static func runFillApply(
        profile profileURL: URL,
        passphrase: String?,
        input: URL,
        outputDir: URL,
        llmModelPath: String? = nil
    ) throws -> FillReport {
        try requireExists(profileURL)
        try requireExists(input)
        let protection = protectionFor(
            passphrase: passphrase,
            derivedAccount: profileURL.deletingPathExtension().lastPathComponent
        )
        let profile = try ProfileStore.load(from: profileURL, protection: protection)
        var plan = try LDAService.planFill(
            target: input,
            profile: profile,
            modelPath: llmModelPath
        )
        // Promote every proposed blank that has a value to confirmed.
        plan.blanks = plan.blanks.map { blank in
            guard blank.status == .proposed,
                  let v = blank.proposedValue,
                  !v.isEmpty else { return blank }
            return Blank(
                id: blank.id,
                location: blank.location,
                label: blank.label,
                context: blank.context,
                proposedFieldID: blank.proposedFieldID,
                proposedValue: blank.proposedValue,
                status: .confirmed,
                candidateFieldIDs: blank.candidateFieldIDs
            )
        }
        return try LDAService.applyFill(
            plan: plan,
            target: input,
            profile: profile,
            outputDir: outputDir
        )
    }
}

// MARK: - extract-profile subcommand

/// extract-profile subcommand: build and save an encrypted CompanyProfile from
/// one or more source documents.
struct ExtractProfile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract-profile",
        abstract: "Build and save an encrypted .ldaprofile from source documents."
    )

    @Option(name: .long, help: "A short human label for the resulting profile.")
    var label: String

    @Option(name: .long, help: "Destination path for the encrypted .ldaprofile.")
    var out: String

    // TODO: passphrase appears in ps output and shell history; move to a Keychain-only path in a future release.
    @Option(name: .long, help: "Passphrase to protect the profile. Optional.")
    var passphrase: String?

    @Option(name: .long, help: "Path to the v2 GGUF model. Required for extraction.")
    var model: String

    @Argument(help: "Source document paths (one or more).")
    var sources: [String]

    func validate() throws {
        guard !sources.isEmpty else {
            throw ValidationError("At least one source document is required.")
        }
    }

    func run() throws {
        do {
            let sourceURLs = sources.map { URL(fileURLWithPath: $0) }
            let (summary, _) = try LDACLI.runExtractProfile(
                sources: sourceURLs,
                label: label,
                out: URL(fileURLWithPath: out),
                passphrase: passphrase,
                llmModelPath: model
            )
            print(try CLIJSON.encode(summary))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}

// MARK: - fill subcommand

/// fill subcommand: load a profile and either plan or apply fills to a target.
///
/// --plan and --apply are mutually exclusive; exactly one is required.
/// --output-dir is required with --apply.
struct Fill: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fill blanks in a document from an encrypted profile."
    )

    @Option(name: .long, help: "Path to the .ldaprofile to fill from.")
    var profile: String

    // TODO: passphrase appears in ps output and shell history; move to a Keychain-only path in a future release.
    @Option(name: .long, help: "Passphrase protecting the profile. Optional.")
    var passphrase: String?

    @Option(name: .long, help: "Path to the fill target (.docx or .pdf).")
    var input: String

    @Option(name: .long, help: "Path to the v2 GGUF model for unmatched blanks. Optional.")
    var model: String?

    @Flag(name: .long, help: "Print the fill plan to stdout without writing anything.")
    var plan: Bool = false

    @Flag(name: .long, help: "Apply the plan and write the filled document.")
    var apply: Bool = false

    @Option(name: .long, help: "Directory to write the filled document (required with --apply).")
    var outputDir: String?

    func validate() throws {
        guard plan || apply else {
            throw ValidationError("Specify either --plan or --apply.")
        }
        guard !(plan && apply) else {
            throw ValidationError("--plan and --apply are mutually exclusive.")
        }
        if apply && (outputDir == nil || outputDir!.isEmpty) {
            throw ValidationError("--output-dir is required with --apply.")
        }
    }

    func run() throws {
        do {
            let profileURL = URL(fileURLWithPath: profile)
            let inputURL = URL(fileURLWithPath: input)

            if plan {
                let entries = try LDACLI.runFillPlan(
                    profile: profileURL,
                    passphrase: passphrase,
                    input: inputURL,
                    llmModelPath: model
                )
                print(try CLIJSON.encode(entries))
            } else {
                guard let outputDirString = outputDir, !outputDirString.isEmpty else {
                    throw ValidationError("--output-dir is required with --apply.")
                }
                fputs("Note: fill --apply re-plans from the current profile state. If you edited the profile after --plan, review the output carefully.\n", stderr)
                let outDir = URL(fileURLWithPath: outputDirString)
                let report = try LDACLI.runFillApply(
                    profile: profileURL,
                    passphrase: passphrase,
                    input: inputURL,
                    outputDir: outDir,
                    llmModelPath: model
                )
                print(try CLIJSON.encode(FillReportJSON(report: report)))
            }
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}
