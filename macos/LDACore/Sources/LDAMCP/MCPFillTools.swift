//
//  MCPFillTools.swift
//  LDAMCP
//
//  Tool implementations for the fill-from-profile MCP tools: extract_profile
//  and fill. Split from MCPServer.swift to keep that file under the 800-line
//  budget.
//
//  Struct sharing precedent: the CLI (LDACLI) uses typed Codable structs
//  (ExtractProfileSummaryJSON, FillPlanEntryJSON, FillReportJSON) for its
//  JSON output. The MCP module does NOT depend on LDACLI (see Package.swift),
//  so those structs are not accessible here. The existing anonymize/restore/
//  detect tools in MCPServer.swift build [String: Any] dictionaries directly
//  rather than going through Codable structs; this file follows that same
//  precedent exactly: summary values are assembled as [String: Any] and
//  serialized by MCPServer's jsonString helper.
//
//  Keychain note: profiles are protected per-document, analogous to the
//  per-document Keychain account pattern in MCPServer for mapping sidecars.
//  The account is derived from the output file's base name.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - Fill tool handlers (extension on MCPServer)

extension MCPServer {

    // MARK: - extract_profile

    /// Run LDAService.extractProfile, save the profile via ProfileStore, and
    /// return the value-free summary as a [String: Any] dictionary.
    ///
    /// Safe summary fields (no field values exposed):
    ///   fieldCount, keys, conflictedKeys, incomplete, failedSources,
    ///   profilePath, createdAt.
    func callExtractProfile(_ arguments: [String: Any]) throws -> [String: Any] {
        // Required: sources (non-empty array of strings)
        guard
            let rawSources = arguments["sources"] as? [String],
            !rawSources.isEmpty
        else {
            throw MCPFillToolError.missingOrEmptyArgument("sources")
        }
        let sources = try rawSources.map { try allowedURL($0, key: "sources") }

        let label = try requireStringArgument(arguments, key: "label")
        let outPath = try requireStringArgument(arguments, key: "out")
        let modelPath = try requireStringArgument(arguments, key: "model")
        let out = try allowedURL(outPath, key: "out")

        let passphrase = arguments["passphrase"] as? String
        let protection = profileProtectionMode(
            from: arguments,
            profileBaseName: ProfileStore.standardAccount(for: out)
        )

        let createdAt = MCPServer.iso8601Now()

        // Optional kind parameter: "company" (default), "individual", or "general".
        // An absent kind silently defaults to .company (documented default).
        // A present but unrecognized kind is an explicit caller error and must
        // be rejected so the caller is not surprised by silent mis-routing.
        let portfolioKind: PortfolioKind
        if let kindString = arguments["kind"] as? String {
            switch kindString {
            case "company":    portfolioKind = .company
            case "individual": portfolioKind = .individual
            case "general":    portfolioKind = .general
            default:
                throw MCPFillToolError.invalidKind(kindString)
            }
        } else {
            portfolioKind = .company
        }

        let result = try LDAService.extractProfile(
            sources: sources,
            label: label,
            kind: portfolioKind,
            modelPath: modelPath,
            createdAtISO8601: createdAt
        )

        _ = passphrase  // consumed via `protection` above; suppress unused-var warning
        try ProfileStore.save(result.profile, to: out, protection: protection)

        // Value-free summary: keys and metadata only, no field values.
        let keys = result.profile.fields.map { $0.key.rawKey }
        let conflictedKeys = result.profile.conflictedKeys.map { $0.rawKey }
        let failedSources: [[String: Any]] = result.failedSources.map { fs in
            ["name": fs.name, "reason": fs.reason]
        }

        return [
            "fieldCount": result.profile.fields.count,
            "keys": keys,
            "conflictedKeys": conflictedKeys,
            "incomplete": result.profile.incomplete,
            "failedSources": failedSources,
            "profilePath": out.path,
            "createdAt": createdAt
        ]
    }

    // MARK: - fill

    /// Dispatch to plan or apply depending on the "mode" argument.
    ///
    /// Exactly one of "profile" (path to .ldaprofile) or "portfolio" (library
    /// entry by name or UUID) must be supplied; they are mutually exclusive.
    /// "passphrase" is only valid with "profile"; using it with "portfolio" is
    /// an error (the library always uses its Keychain key).
    func callFill(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let mode = arguments["mode"] as? String else {
            throw MCPFillToolError.missingOrEmptyArgument("mode")
        }
        guard mode == "plan" || mode == "apply" else {
            throw MCPFillToolError.invalidMode(mode)
        }

        let hasProfile = (arguments["profile"] as? String).map { !$0.isEmpty } ?? false
        let portfolioName = (arguments["portfolio"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hasPortfolio = portfolioName != nil
        let passphrase = arguments["passphrase"] as? String
        let hasPassphrase = passphrase.map { !$0.isEmpty } ?? false

        // Mutual exclusion: exactly one of profile or portfolio must be provided.
        if hasProfile && hasPortfolio {
            throw MCPPortfolioToolError.profileAndPortfolioMutuallyExclusive
        }
        if !hasProfile && !hasPortfolio {
            throw MCPPortfolioToolError.neitherProfileNorPortfolio
        }
        // passphrase is only valid with profile.
        if hasPortfolio && hasPassphrase {
            throw MCPPortfolioToolError.passphraseWithPortfolio
        }

        let inputPath = try requireStringArgument(arguments, key: "input")
        let inputURL = try allowedURL(inputPath, key: "input")
        let modelPath = (arguments["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let profile: ClientPortfolio
        if hasPortfolio, let nameOrID = portfolioName {
            // Load from library via name or UUID.
            let library = try PortfolioLibrary(rootDirectory: MCPServer.effectiveLibraryRoot)
            let summaries = try library.list()
            let (id, _) = try PortfolioLibrary.resolve(nameOrID: nameOrID, from: summaries)
            profile = try library.load(id: id)
        } else {
            // Load from explicit profile file path.
            let profilePath = try requireStringArgument(arguments, key: "profile")
            let profileURL = try allowedURL(profilePath, key: "profile")
            if let passphrase, !passphrase.isEmpty {
                profile = try ProfileStore.load(from: profileURL, protection: .passphrase(passphrase))
            } else {
                profile = try ProfileStore.loadWithAccountFallback(from: profileURL)
            }
        }

        if mode == "plan" {
            return try callFillPlan(
                inputURL: inputURL,
                profile: profile,
                modelPath: modelPath
            )
        } else {
            guard
                let outputDirString = arguments["output_dir"] as? String,
                !outputDirString.isEmpty
            else {
                throw MCPFillToolError.missingOrEmptyArgument("output_dir")
            }
            return try callFillApply(
                inputURL: inputURL,
                profile: profile,
                outputDir: try allowedURL(outputDirString, key: "output_dir"),
                modelPath: modelPath
            )
        }
    }

    // MARK: - fill plan

    private func callFillPlan(
        inputURL: URL,
        profile: ClientPortfolio,
        modelPath: String?
    ) throws -> [String: Any] {
        let plan = try LDAService.planFill(
            target: inputURL,
            profile: profile,
            modelPath: modelPath
        )

        let entries: [[String: Any]] = plan.blanks.map { blank in
            fillPlanEntryDict(blank: blank, profile: profile)
        }

        return ["entries": entries]
    }

    // MARK: - fill apply

    private func callFillApply(
        inputURL: URL,
        profile: ClientPortfolio,
        outputDir: URL,
        modelPath: String?
    ) throws -> [String: Any] {
        var plan = try LDAService.planFill(
            target: inputURL,
            profile: profile,
            modelPath: modelPath
        )

        // Promote every proposed blank that has a value to confirmed.
        plan.blanks = plan.blanks.map { blank in
            guard blank.status == .proposed,
                  let v = blank.proposedValue,
                  !v.isEmpty else { return blank }
            var promoted = blank
            promoted.status = .confirmed
            return promoted
        }

        let report = try LDAService.applyFill(
            plan: plan,
            target: inputURL,
            profile: profile,
            outputDir: outputDir
        )

        // Value-free report: no filled values included.
        let skipped: [[String: Any]] = report.skipped.map { s in
            [
                "label": s.label,
                "locationDescription": s.locationDescription,
                "reason": s.reason
            ]
        }

        return [
            "outputURL": report.outputURL.path,
            "filledCount": report.filledCount,
            "skipped": skipped
        ]
    }

    // MARK: - Shared helpers

    /// Build a plan entry dictionary for one blank. Values are included (the
    /// plan output is intended for human review; only the apply output is
    /// value-free). This mirrors the shape of FillPlanEntryJSON in LDACLI.
    private func fillPlanEntryDict(blank: Blank, profile: ClientPortfolio) -> [String: Any] {
        var entry: [String: Any] = [
            "label": blank.label,
            "locationDescription": locationDescription(blank.location),
            "status": blank.status.rawValue
        ]

        // Resolve proposedFieldKey from proposedFieldID.
        if let fieldID = blank.proposedFieldID,
           let field = profile.fields.first(where: { $0.id == fieldID }) {
            entry["proposedFieldKey"] = field.key.rawKey
        }

        if let value = blank.proposedValue {
            entry["proposedValue"] = value
        }

        // candidates: present only for ambiguous blanks (.proposed with nil
        // proposedFieldID but non-nil candidateFieldIDs).
        if blank.status == .proposed,
           blank.proposedFieldID == nil,
           let candidateIDs = blank.candidateFieldIDs,
           !candidateIDs.isEmpty {
            let candidateKeys = candidateIDs.compactMap { cid in
                profile.fields.first(where: { $0.id == cid })?.key.rawKey
            }
            if !candidateKeys.isEmpty {
                entry["candidates"] = candidateKeys
            }
        }

        return entry
    }

    /// Human-readable location description. Mirrors CLIFill.FillPlanEntryJSON.
    private func locationDescription(_ location: BlankLocation) -> String {
        switch location {
        case .acroFormField(let name):
            return "field \(name)"
        case .textSpan(let start, let end):
            return "offset \(start)-\(end)"
        }
    }

    /// Require a non-empty string argument by key.
    func requireStringArgument(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw MCPFillToolError.missingOrEmptyArgument(key)
        }
        return value
    }

    /// Choose the profile protection mode from the arguments. A passphrase,
    /// when present and non-empty, selects PBKDF2 passphrase protection;
    /// otherwise the server uses the unified standard Keychain account (bare
    /// base name, no prefix) for new saves. Use loadWithAccountFallback on
    /// load to handle files saved by any prior edge.
    func profileProtectionMode(
        from arguments: [String: Any],
        profileBaseName: String
    ) -> MappingProtection {
        if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(account: profileBaseName)
    }
}

// MARK: - MCPFillToolError

/// Errors raised while validating fill tool-call arguments at the MCP edge.
enum MCPFillToolError: Error {
    case missingOrEmptyArgument(String)
    case invalidMode(String)
    case invalidKind(String)

    var message: String {
        switch self {
        case .missingOrEmptyArgument(let key):
            return "Missing or empty required argument: \(key)"
        case .invalidMode(let mode):
            return "Invalid fill mode \"\(mode)\": must be \"plan\" or \"apply\""
        case .invalidKind(let kind):
            return "kind must be 'company', 'individual', or 'general'; got '\(kind)'"
        }
    }
}
