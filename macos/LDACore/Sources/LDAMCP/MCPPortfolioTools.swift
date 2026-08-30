//
//  MCPPortfolioTools.swift
//  LDAMCP
//
//  Tool implementations for the read-only portfolio portal: portfolio_list and
//  portfolio_show. Split from MCPFillTools.swift to keep that file under the
//  800-line budget.
//
//  Resolution sharing: PortfolioResolutionError and PortfolioLibrary.resolve are
//  defined in LDACore (PortfolioLibrary.swift) so both the LDACLI edge and this
//  LDAMCP edge share the same semantics without either depending on the other.
//  This is preferred over replicating the resolution logic here (per task spec:
//  "PREFER the move").
//
//  Testing seam: MCPServer.libraryRootForTesting is an internal static var that
//  tests can set to inject a hermetic temp root. Production code always passes nil
//  to PortfolioLibrary(rootDirectory:), which then falls back to the ApplicationSupport
//  default.
//
//  Value-free contract: neither tool ever includes field values in its output.
//  portfolio_list returns summaries (id, label, kind, dates, fieldCount, conflicted).
//  portfolio_show adds rawKeys and conflictedKeys. No field value appears in
//  either response.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - Testing seam

extension MCPServer {
#if DEBUG
    /// Debug-only injection of a custom library root. Production uses
    /// PortfolioLibrary's Application Support default. Tests point this at a
    /// hermetic temp directory before exercising portfolio_list or
    /// portfolio_show, and clear it in defer.
    ///
    /// Compiled out of release builds and lock guarded; see TestSeam. Before
    /// this change the seam was a bare mutable static reachable in the shipped
    /// MCP server, which is a redirect of where client portfolios are read
    /// from.
    internal static let librarySeam = TestSeam<URL>()

    internal static var libraryRootForTesting: URL? {
        get { librarySeam.value }
        set { librarySeam.value = newValue }
    }
#endif

    /// The library root the portfolio tools should use: the debug seam when a
    /// test installed one, otherwise nil so PortfolioLibrary picks its own
    /// Application Support default. Release builds always return nil.
    static var effectiveLibraryRoot: URL? {
#if DEBUG
        return libraryRootForTesting
#else
        return nil
#endif
    }
}

// MARK: - Portfolio tool handlers (extension on MCPServer)

extension MCPServer {

    // MARK: - portfolio_list

    /// Return all portfolios in the library as a value-free sorted array.
    ///
    /// Output shape: { "portfolios": [ { id, label, kind, createdAtISO8601,
    ///   modifiedAtISO8601, fieldCount, conflicted }, ... ] }
    ///
    /// The array is sorted by label ascending (stable tiebreak by UUID string),
    /// matching the CLI's portfolio list output.
    func callPortfolioList(_ arguments: [String: Any]) throws -> [String: Any] {
        let library = try PortfolioLibrary(rootDirectory: MCPServer.effectiveLibraryRoot)
        let summaries = try library.list()

        let portfolios: [[String: Any]] = summaries.map { summary in
            summaryDict(summary)
        }

        return ["portfolios": portfolios]
    }

    // MARK: - portfolio_show

    /// Return a single portfolio's value-free detail (summary + rawKeys +
    /// conflictedKeys) identified by UUID string or label (case-insensitive,
    /// unique match).
    ///
    /// Output shape: { id, label, kind, createdAtISO8601, modifiedAtISO8601,
    ///   fieldCount, conflicted, rawKeys: [String], conflictedKeys: [String] }
    func callPortfolioShow(_ arguments: [String: Any]) throws -> [String: Any] {
        let nameOrID = try requireStringArgument(arguments, key: "portfolio")

        let library = try PortfolioLibrary(rootDirectory: MCPServer.effectiveLibraryRoot)
        let summaries = try library.list()

        let (id, _) = try PortfolioLibrary.resolve(nameOrID: nameOrID, from: summaries)
        let portfolio = try library.load(id: id)

        var dict = summaryDict(PortfolioSummary(
            id: id,
            label: portfolio.label,
            kind: portfolio.kind,
            createdAtISO8601: portfolio.createdAtISO8601,
            modifiedAtISO8601: portfolio.modifiedAtISO8601,
            fieldCount: portfolio.fields.count,
            conflicted: !portfolio.conflictedKeys.isEmpty
        ))

        dict["rawKeys"] = portfolio.fields.map { $0.key.rawKey }
        dict["conflictedKeys"] = portfolio.conflictedKeys.map { $0.rawKey }

        return dict
    }

    // MARK: - Shared helpers

    /// Build a value-free summary dictionary for one PortfolioSummary.
    private func summaryDict(_ summary: PortfolioSummary) -> [String: Any] {
        [
            "id": summary.id.uuidString,
            "label": summary.label,
            "kind": summary.kind.rawValue,
            "createdAtISO8601": summary.createdAtISO8601,
            "modifiedAtISO8601": summary.modifiedAtISO8601,
            "fieldCount": summary.fieldCount,
            "conflicted": summary.conflicted
        ]
    }
}

// MARK: - describe arms for PortfolioResolutionError

extension MCPServer {
    /// Actionable human-readable message for a PortfolioResolutionError.
    func describe(_ error: PortfolioResolutionError) -> String {
        switch error {
        case .notFound(let nameOrID):
            return "No portfolio found matching '\(nameOrID)'. " +
                   "Run portfolio_list to see available portfolios."
        case .ambiguous(let nameOrID, let candidates):
            let list = candidates.joined(separator: ", ")
            return "Multiple portfolios match '\(nameOrID)': \(list). " +
                   "Use the portfolio UUID for an exact match."
        }
    }
}

// MARK: - MCPPortfolioToolError

/// Errors raised while validating portfolio tool-call arguments at the MCP edge.
enum MCPPortfolioToolError: Error {
    /// Both "profile" and "portfolio" were supplied; exactly one is required.
    case profileAndPortfolioMutuallyExclusive
    /// Neither "profile" nor "portfolio" was supplied; exactly one is required.
    case neitherProfileNorPortfolio
    /// "passphrase" was supplied with "portfolio"; the library uses Keychain only.
    case passphraseWithPortfolio

    var message: String {
        switch self {
        case .profileAndPortfolioMutuallyExclusive:
            return "Exactly one of \"profile\" or \"portfolio\" must be supplied; both were provided. " +
                   "Remove one to resolve the conflict."
        case .neitherProfileNorPortfolio:
            return "Exactly one of \"profile\" (path to a .ldaprofile file) or \"portfolio\" " +
                   "(library entry by name or UUID) must be supplied; neither was provided."
        case .passphraseWithPortfolio:
            return "\"passphrase\" cannot be combined with \"portfolio\": the library always uses " +
                   "its Keychain key. Supply \"profile\" instead if you need passphrase protection."
        }
    }
}
