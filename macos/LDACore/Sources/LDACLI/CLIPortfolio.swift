//
//  CLIPortfolio.swift
//  LDACLI
//
//  CLI subcommands for the read-only portfolio portal: portfolio list and
//  portfolio show. Also houses the LDACLI helpers used by the fill --portfolio
//  path (runFillPlanFromPortfolio).
//
//  Command tree additions:
//    - portfolio list:       value-free JSON array of PortfolioSummary objects,
//                            sorted by label (then UUID for stable ordering).
//    - portfolio show <id>:  one summary + field rawKeys + conflictedKeys.
//                            Values are NEVER included.
//
//  Resolution for show (and fill --portfolio):
//    1. Exact UUID match.
//    2. Case-insensitive label match. Unique match succeeds; ambiguous match
//       lists candidate labels in the error; no match produces a clear
//       "not found" error.
//
//  Testable static helpers:
//    - LDACLI.runPortfolioList(libraryRoot:)
//    - LDACLI.runPortfolioShow(nameOrID:libraryRoot:)
//    - LDACLI.runFillPlanFromPortfolio(nameOrID:libraryRoot:input:llmModelPath:)
//
//  All helpers accept an optional libraryRoot URL (nil = production default).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ArgumentParser
import LDACore

// MARK: - JSON summary types

/// The value-free detail produced by portfolio show.
/// Extends PortfolioSummary with the list of field rawKeys.
/// Field VALUES are never included.
public struct PortfolioDetailJSON: Codable, Equatable {
    // MARK: Summary fields (mirrors PortfolioSummary)
    public let id: String
    public let label: String
    public let kind: String
    public let createdAtISO8601: String
    public let modifiedAtISO8601: String
    public let fieldCount: Int
    public let conflicted: Bool
    // MARK: Keys (raw strings, no values)
    /// All rawKey strings in field order.
    public let rawKeys: [String]
    /// RawKey strings for conflicted keys.
    public let conflictedKeys: [String]

    public init(id: UUID, portfolio: ClientPortfolio) {
        self.id = id.uuidString
        self.label = portfolio.label
        self.kind = portfolio.kind.rawValue
        self.createdAtISO8601 = portfolio.createdAtISO8601
        self.modifiedAtISO8601 = portfolio.modifiedAtISO8601
        self.fieldCount = portfolio.fields.count
        self.conflicted = !portfolio.conflictedKeys.isEmpty
        self.rawKeys = portfolio.fields.map { $0.key.rawKey }
        self.conflictedKeys = portfolio.conflictedKeys.map { $0.rawKey }
    }
}

/// The value-free summary produced by portfolio list.
/// Mirrors PortfolioSummary exactly (no values, only metadata).
public struct PortfolioSummaryJSON: Codable, Equatable {
    public let id: String
    public let label: String
    public let kind: String
    public let createdAtISO8601: String
    public let modifiedAtISO8601: String
    public let fieldCount: Int
    public let conflicted: Bool

    public init(summary: PortfolioSummary) {
        self.id = summary.id.uuidString
        self.label = summary.label
        self.kind = summary.kind.rawValue
        self.createdAtISO8601 = summary.createdAtISO8601
        self.modifiedAtISO8601 = summary.modifiedAtISO8601
        self.fieldCount = summary.fieldCount
        self.conflicted = summary.conflicted
    }
}

// MARK: - LDACLI helpers

extension LDACLI {

    // MARK: runPortfolioList

    /// List all portfolios in the library as value-free JSON summaries, sorted
    /// by label (then UUID for stability).
    ///
    /// - Parameter libraryRoot: Path to the library root. Nil uses the
    ///   production default (<ApplicationSupport>/LDA/Portfolios).
    /// - Returns: Array of PortfolioSummaryJSON in label-ascending order.
    public static func runPortfolioList(
        libraryRoot: URL? = nil
    ) throws -> [PortfolioSummaryJSON] {
        let library = try PortfolioLibrary(rootDirectory: libraryRoot)
        let summaries = try library.list()
        return summaries.map(PortfolioSummaryJSON.init)
    }

    // MARK: runPortfolioShow

    /// Show a single portfolio's value-free detail (summary + rawKeys +
    /// conflictedKeys, never values).
    ///
    /// Resolution order:
    ///   1. Exact UUID match.
    ///   2. Case-insensitive label match. Unique succeeds; ambiguous or absent
    ///      throws a descriptive PortfolioResolutionError.
    ///
    /// - Parameters:
    ///   - nameOrID: A UUID string or a label (case-insensitive).
    ///   - libraryRoot: Path to the library root. Nil uses the production default.
    /// - Returns: PortfolioDetailJSON for the matched portfolio.
    public static func runPortfolioShow(
        nameOrID: String,
        libraryRoot: URL? = nil
    ) throws -> PortfolioDetailJSON {
        let library = try PortfolioLibrary(rootDirectory: libraryRoot)
        let summaries = try library.list()

        let (id, _) = try resolvePortfolio(nameOrID: nameOrID, from: summaries)
        let portfolio = try library.load(id: id)
        return PortfolioDetailJSON(id: id, portfolio: portfolio)
    }

    // MARK: runFillPlanFromPortfolio

    /// Load a portfolio from the library by name or UUID, then run planFill on
    /// the target document.
    ///
    /// This is the fill --portfolio path: the portfolio is loaded via the
    /// library's fixed Keychain account ("library"), not a per-file passphrase.
    /// Passing a passphrase together with --portfolio is a validation error
    /// (enforced in Fill.validate(), not here).
    ///
    /// - Parameters:
    ///   - nameOrID: UUID string or label (case-insensitive, unique).
    ///   - libraryRoot: Library root URL. Nil uses the production default.
    ///   - input: Target document (.docx or .pdf).
    ///   - llmModelPath: Optional GGUF model for unmatched blanks.
    /// - Returns: Fill plan entries (values present for human review).
    public static func runFillPlanFromPortfolio(
        nameOrID: String,
        libraryRoot: URL? = nil,
        input: URL,
        llmModelPath: String? = nil
    ) throws -> [FillPlanEntryJSON] {
        try requireExists(input)
        let library = try PortfolioLibrary(rootDirectory: libraryRoot)
        let summaries = try library.list()
        let (id, _) = try resolvePortfolio(nameOrID: nameOrID, from: summaries)
        let portfolio = try library.load(id: id)
        let plan = try LDAService.planFill(
            target: input,
            profile: portfolio,
            modelPath: llmModelPath
        )
        return plan.blanks.map { FillPlanEntryJSON(blank: $0, profile: portfolio) }
    }

    // MARK: runFillApplyFromPortfolio

    /// Load a portfolio from the library, plan the fill, promote proposed-with-value
    /// blanks to confirmed, and apply the fill.
    ///
    /// - Parameters:
    ///   - nameOrID: UUID string or label (case-insensitive, unique).
    ///   - libraryRoot: Library root URL. Nil uses the production default.
    ///   - input: Target document.
    ///   - outputDir: Directory to write the filled document.
    ///   - llmModelPath: Optional GGUF model for unmatched blanks.
    /// - Returns: FillReport (value-free at the CLI edge via FillReportJSON).
    public static func runFillApplyFromPortfolio(
        nameOrID: String,
        libraryRoot: URL? = nil,
        input: URL,
        outputDir: URL,
        llmModelPath: String? = nil
    ) throws -> FillReport {
        try requireExists(input)
        let library = try PortfolioLibrary(rootDirectory: libraryRoot)
        let summaries = try library.list()
        let (id, _) = try resolvePortfolio(nameOrID: nameOrID, from: summaries)
        let portfolio = try library.load(id: id)
        var plan = try LDAService.planFill(
            target: input,
            profile: portfolio,
            modelPath: llmModelPath
        )
        plan.blanks = plan.blanks.map { blank in
            guard blank.status == .proposed,
                  let v = blank.proposedValue,
                  !v.isEmpty else { return blank }
            var promoted = blank
            promoted.status = .confirmed
            return promoted
        }
        return try LDAService.applyFill(
            plan: plan,
            target: input,
            profile: portfolio,
            outputDir: outputDir
        )
    }

    // MARK: Resolution helper

    /// Resolve a name-or-id string to a (UUID, PortfolioSummary) pair.
    ///
    /// Delegates to PortfolioLibrary.resolve (defined in LDACore) so the
    /// resolution semantics are shared with the MCP edge without either edge
    /// depending on the other.
    internal static func resolvePortfolio(
        nameOrID: String,
        from summaries: [PortfolioSummary]
    ) throws -> (UUID, PortfolioSummary) {
        try PortfolioLibrary.resolve(nameOrID: nameOrID, from: summaries)
    }
}

// MARK: - Portfolio command group

/// portfolio subcommand group: list and show.
struct Portfolio: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and inspect portfolios in the portfolio library.",
        subcommands: [PortfolioList.self, PortfolioShow.self]
    )
}

// MARK: - portfolio list

/// portfolio list: print a value-free JSON array of all portfolio summaries.
struct PortfolioList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all portfolios (value-free JSON array of summaries)."
    )

    func run() throws {
        do {
            let summaries = try LDACLI.runPortfolioList()
            print(try CLIJSON.encode(summaries))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}

// MARK: - portfolio show

/// portfolio show <name-or-id>: print a value-free detail for one portfolio.
struct PortfolioShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one portfolio (summary + field rawKeys; no values)."
    )

    @Argument(help: "Portfolio UUID or label (case-insensitive, must be unique).")
    var nameOrID: String

    func run() throws {
        do {
            let detail = try LDACLI.runPortfolioShow(nameOrID: nameOrID)
            print(try CLIJSON.encode(detail))
        } catch {
            throw CLIRuntimeError(error)
        }
    }
}
