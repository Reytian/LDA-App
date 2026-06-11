//
//  FillPlanner.swift
//  LDACore
//
//  Plans blank fills for one target document by matching blanks to a
//  ClientPortfolio in two stages:
//
//  1. Synonym pass (no model required): normalizes the blank label and looks it
//     up in a built-in synonym table. A table hit with exactly one profile field
//     for that key yields a .proposed blank with proposedFieldID and
//     proposedValue set. A hit with several fields (e.g. multiple directorName
//     entries) yields .proposed with both values nil so the review UI can present
//     a picker. A miss leaves the blank .unmatched for the next stage.
//
//  2. Model fallback (only when completer is supplied): blanks still .unmatched
//     after the synonym pass are sent to the LLM in batches of at most
//     modelBatchSize blanks per call. The model receives a numbered catalog of
//     ALL profile fields and a numbered list of blanks (label + context), returns
//     a JSON array of match decisions, and each valid decision with an in-range
//     field index is applied. Batch errors are caught and leave the batch
//     unmatched; matching is best-effort and never throws out of plan().
//
//  Idempotence: blanks that arrive with status other than .unmatched are passed
//  through unchanged. Re-planning after user review decisions must not clobber
//  .confirmed or .rejected blanks.
//
//  Label normalization pipeline (applied identically to blank labels and to
//  synonym table keys at construction so the mapping is robust by construction):
//    1. Lowercase
//    2. Strip leading "please " then "insert " then "enter "
//    3. Strip leading "the "
//    4. Strip leading "name of "
//    5. Collapse internal whitespace to single spaces, trim
//    6. Strip trailing ":" and full-width ":" (U+FF1A)
//
//  The table keys are run through the same normalizer at build time, so the
//  raw table entries in synonymTable can be written in their natural English/
//  Chinese form and still match any normalized label that maps to them.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - FillPlanner

/// A pure, stateless namespace for the fill-planning operation.
///
/// All inputs are passed explicitly; there is no shared mutable state, no
/// clock, and no randomness. The completer is the only source of
/// non-determinism (and is absent when completer is nil).
public enum FillPlanner {

    // MARK: - Public constants

    /// Maximum number of blanks sent to the model in a single batch call.
    public static let modelBatchSize = 12

    // MARK: - Public API

    /// Plan blank fills for one target document.
    ///
    /// - Parameters:
    ///   - blanks: the blanks to plan, in document order. Blanks with status
    ///     other than .unmatched are passed through unchanged (idempotence).
    ///   - profile: the company profile supplying candidate field values.
    ///   - completer: optional LLM backend. When nil, only the synonym pass
    ///     runs; blanks that miss the table stay .unmatched.
    ///   - prompts: prompt store used to assemble the blank-match prompt.
    ///     Defaults to a fresh PromptStore seeded with the shipped defaults.
    /// - Returns: the same blanks in the same order, with status, proposedFieldID,
    ///   and proposedValue updated where a match was found.
    public static func plan(
        blanks: [Blank],
        profile: ClientPortfolio,
        completer: TextCompleter?,
        prompts: PromptStore = PromptStore()
    ) -> [Blank] {
        var result = blanks

        // Stage 1: synonym pass.
        result = synonymPass(blanks: result, profile: profile)

        // Stage 2: model fallback (only when a completer is provided).
        if let completer = completer {
            result = modelPass(blanks: result, profile: profile, completer: completer, prompts: prompts)
        }

        return result
    }

    // MARK: - Normalized synonym table (cached)

    /// Cached normalized lookup table built once at startup.
    /// Using a static let ensures buildNormalizedTable() runs exactly once
    /// regardless of how many plan() calls are made.
    private static let normalizedTable: [String: ProfileFieldKey] = buildNormalizedTable()

    // MARK: - Stage 1: synonym pass

    private static func synonymPass(blanks: [Blank], profile: ClientPortfolio) -> [Blank] {
        // Use the cached normalized table.
        let table = normalizedTable

        return blanks.map { blank in
            // Idempotence: skip non-.unmatched blanks.
            guard blank.status == .unmatched else { return blank }

            let normalized = normalize(blank.label)
            guard !normalized.isEmpty, let key = table[normalized] else { return blank }

            // Collect all profile fields that match this key.
            let matching = profile.fields.filter { $0.key == key }
            guard !matching.isEmpty else { return blank }

            if matching.count == 1 {
                // Unambiguous: propose the single field.
                let f = matching[0]
                return Blank(
                    id: blank.id,
                    location: blank.location,
                    label: blank.label,
                    context: blank.context,
                    proposedFieldID: f.id,
                    proposedValue: f.value,
                    status: .proposed
                )
            } else {
                // Ambiguous: mark .proposed but leave pick to the UI.
                // Populate candidateFieldIDs so the CLI can surface the
                // candidate rawKeys without re-querying the profile.
                let candidateIDs = matching.map { $0.id }
                return Blank(
                    id: blank.id,
                    location: blank.location,
                    label: blank.label,
                    context: blank.context,
                    proposedFieldID: nil,
                    proposedValue: nil,
                    status: .proposed,
                    candidateFieldIDs: candidateIDs
                )
            }
        }
    }

    // MARK: - Stage 2: model pass

    private static func modelPass(
        blanks: [Blank],
        profile: ClientPortfolio,
        completer: TextCompleter,
        prompts: PromptStore
    ) -> [Blank] {
        // Collect the global indices of blanks that still need matching.
        let unmatchedIndices = blanks.indices.filter { blanks[$0].status == .unmatched }
        guard !unmatchedIndices.isEmpty else { return blanks }

        // Build the numbered field catalog (1-based) once for all batches.
        let catalog = buildCatalog(profile.fields)

        var result = blanks

        // Process in batches of at most modelBatchSize.
        let batches = unmatchedIndices.chunked(into: modelBatchSize)
        for batchGlobalIndices in batches {
            let batchBlanks = batchGlobalIndices.map { blanks[$0] }
            let batchText = buildBlanksText(batchBlanks)

            let userTurn = prompts.blankMatchUser(catalog: catalog, blanks: batchText)
            let prompt = LLMEngine.buildChatMLPrompt(
                system: prompts.currentBlankMatchSystem,
                user: userTurn
            )

            let modelOutput: String
            do {
                modelOutput = try completer.complete(
                    prompt: prompt,
                    maxTokens: nil,
                    stop: ["<|im_end|>"]
                )
            } catch {
                // Matching is best-effort. A completer error leaves the whole
                // batch unmatched; we do not propagate the error out of plan().
                continue
            }

            let rows = ProfileJSONParser.parseBlankMatchRows(modelOutput)
            // rows with blank index out of the batch range are ignored.
            for row in rows {
                // row.blank is 1-based within this batch.
                let localIndex = row.blank - 1
                guard localIndex >= 0, localIndex < batchGlobalIndices.count else { continue }

                let globalIndex = batchGlobalIndices[localIndex]
                guard result[globalIndex].status == .unmatched else { continue }

                guard
                    let fieldIndex = row.field,
                    fieldIndex >= 1,
                    fieldIndex <= profile.fields.count
                else {
                    // null field or out-of-range: stays .unmatched.
                    continue
                }

                let matchedField = profile.fields[fieldIndex - 1]
                // Prefer the model's adapted value, but only when it is
                // non-empty: an empty or whitespace-only adapted value means
                // the model produced no usable text, so fall back to the
                // canonical field value rather than silently erasing it.
                let adapted = row.value ?? ""
                let proposedValue = adapted.trimmingCharacters(in: .whitespaces).isEmpty
                    ? matchedField.value
                    : adapted

                result[globalIndex] = Blank(
                    id: result[globalIndex].id,
                    location: result[globalIndex].location,
                    label: result[globalIndex].label,
                    context: result[globalIndex].context,
                    proposedFieldID: matchedField.id,
                    proposedValue: proposedValue,
                    status: .proposed
                )
            }
        }

        return result
    }

    // MARK: - Catalog builder

    /// Build a numbered (1-based) field catalog string for the model prompt.
    private static func buildCatalog(_ fields: [ProfileField]) -> String {
        fields.enumerated()
            .map { index, f in "\(index + 1). \(f.key.rawKey): \(f.value)" }
            .joined(separator: "\n")
    }

    /// Build the numbered (1-based) blanks list for the model prompt.
    private static func buildBlanksText(_ blanks: [Blank]) -> String {
        blanks.enumerated()
            .map { index, b in "\(index + 1). label: \"\(b.label)\" context: \"\(b.context)\"" }
            .joined(separator: "\n")
    }

    // MARK: - Label normalization

    /// Normalize a blank label for synonym lookup.
    ///
    /// Pipeline (order matters):
    ///   1. Lowercase
    ///   2. Strip leading "please "
    ///   3. Strip leading "insert "
    ///   4. Strip leading "enter "
    ///   5. Strip leading "the "
    ///   6. Strip leading "name of "
    ///   7. Collapse internal whitespace, trim
    ///   8. Strip trailing ASCII colon ":" and full-width colon "\u{FF1A}"
    static func normalize(_ label: String) -> String {
        var s = label.lowercased()

        // Strip leading instruction words (order: please, insert, enter).
        if s.hasPrefix("please ") { s = String(s.dropFirst("please ".count)) }
        if s.hasPrefix("insert ") { s = String(s.dropFirst("insert ".count)) }
        if s.hasPrefix("enter ") { s = String(s.dropFirst("enter ".count)) }

        // Strip leading article / "name of ".
        if s.hasPrefix("the ") { s = String(s.dropFirst("the ".count)) }
        if s.hasPrefix("name of ") { s = String(s.dropFirst("name of ".count)) }

        // Collapse whitespace.
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // Strip trailing colon (ASCII or full-width).
        while s.hasSuffix(":") || s.hasSuffix("\u{FF1A}") {
            s = String(s.dropLast())
        }

        return s
    }

    // MARK: - Synonym table

    /// The raw synonym table: each array of strings maps to one ProfileFieldKey.
    /// Keys are normalized at build time so the raw strings can be written in
    /// their natural form.
    private static let synonymTable: [(ProfileFieldKey, [String])] = [
        (.companyName, [
            "company name", "name of company", "corporate name", "company",
            "公司名称", "公司名稱"
        ]),
        (.companyNameLocal, [
            "chinese name", "local name", "中文名称"
        ]),
        (.jurisdiction, [
            "jurisdiction", "place of incorporation", "state of incorporation",
            "管辖法域", "注册地"
        ]),
        (.companyNumber, [
            "company number", "registration number", "registration no", "reg no",
            "certificate number", "统一社会信用代码", "注册号"
        ]),
        (.incorporationDate, [
            "date of incorporation", "incorporation date", "date of registration",
            "成立日期", "注册日期"
        ]),
        (.registeredOffice, [
            "registered office", "registered address", "registered office address",
            "注册地址", "注册办事处"
        ]),
        (.authorizedCapital, [
            "authorized capital", "authorised capital", "注册资本"
        ]),
        (.issuedCapital, [
            "issued capital", "issued share capital"
        ]),
        (.parValue, [
            "par value", "nominal value", "面值"
        ]),
        (.directorName, [
            "director", "director name", "name of director", "董事", "董事姓名"
        ]),
        (.shareholderName, [
            "shareholder", "member", "股东", "股东姓名"
        ]),
        (.companySecretary, [
            "company secretary", "secretary", "公司秘书"
        ]),
        (.registeredAgent, [
            "registered agent", "注册代理人"
        ]),
        (.entityKind, [
            "entity type", "company type", "公司类型"
        ])
    ]

    /// Build a normalized [String: ProfileFieldKey] lookup from synonymTable.
    /// Both the raw synonym strings AND the normalized table keys are stored so
    /// any normalized label that maps to a table entry will hit.
    private static func buildNormalizedTable() -> [String: ProfileFieldKey] {
        var table: [String: ProfileFieldKey] = [:]
        for (key, synonyms) in synonymTable {
            for synonym in synonyms {
                let normalized = normalize(synonym)
                if !normalized.isEmpty {
                    table[normalized] = key
                }
            }
        }
        return table
    }
}

// MARK: - Array chunking helper

private extension Array {
    /// Split the array into sub-arrays of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
