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
        let sources = rawSources.map { URL(fileURLWithPath: $0) }

        let label = try requireStringArgument(arguments, key: "label")
        let outPath = try requireStringArgument(arguments, key: "out")
        let modelPath = try requireStringArgument(arguments, key: "model")
        let out = URL(fileURLWithPath: outPath)

        let passphrase = arguments["passphrase"] as? String
        let protection = profileProtectionMode(
            from: arguments,
            profileBaseName: out.deletingPathExtension().lastPathComponent
        )

        let createdAt = MCPServer.iso8601Now()

        let result = try LDAService.extractProfile(
            sources: sources,
            label: label,
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
    func callFill(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let mode = arguments["mode"] as? String else {
            throw MCPFillToolError.missingOrEmptyArgument("mode")
        }
        guard mode == "plan" || mode == "apply" else {
            throw MCPFillToolError.invalidMode(mode)
        }

        let profilePath = try requireStringArgument(arguments, key: "profile")
        let inputPath = try requireStringArgument(arguments, key: "input")
        let profileURL = URL(fileURLWithPath: profilePath)
        let inputURL = URL(fileURLWithPath: inputPath)

        let protection = profileProtectionMode(
            from: arguments,
            profileBaseName: profileURL.deletingPathExtension().lastPathComponent
        )

        let profile = try ProfileStore.load(from: profileURL, protection: protection)

        let modelPath = (arguments["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }

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
                outputDir: URL(fileURLWithPath: outputDirString),
                modelPath: modelPath
            )
        }
    }

    // MARK: - fill plan

    private func callFillPlan(
        inputURL: URL,
        profile: CompanyProfile,
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
        profile: CompanyProfile,
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
    private func fillPlanEntryDict(blank: Blank, profile: CompanyProfile) -> [String: Any] {
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
    /// otherwise the server uses a Keychain account derived from the profile
    /// base name, one key per profile file.
    func profileProtectionMode(
        from arguments: [String: Any],
        profileBaseName: String
    ) -> MappingProtection {
        if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(
            account: "\(MCPServer.defaultKeychainAccount).profile.\(profileBaseName)"
        )
    }
}

// MARK: - MCPFillToolError

/// Errors raised while validating fill tool-call arguments at the MCP edge.
enum MCPFillToolError: Error {
    case missingOrEmptyArgument(String)
    case invalidMode(String)

    var message: String {
        switch self {
        case .missingOrEmptyArgument(let key):
            return "Missing or empty required argument: \(key)"
        case .invalidMode(let mode):
            return "Invalid fill mode \"\(mode)\": must be \"plan\" or \"apply\""
        }
    }
}
