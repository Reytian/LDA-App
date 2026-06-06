//
//  CoreTypes.swift
//  LDACore
//
//  Frozen public domain types shared by every engine and every face.
//
//  Offset convention: ALL offsets in this file are UTF-16 code-unit offsets,
//  NSRange-compatible, because DeterministicEngine runs NSRegularExpression over
//  the text as NSString. Downstream code must treat Span.start and Span.end as
//  UTF-16 offsets, not Character or Unicode scalar offsets.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Entity types

/// The kinds of entity an engine can detect. Raw values are the stable wire
/// strings used in tokens, mappings, and the LLM prompt contract.
public enum EntityType: String, Codable, Sendable, CaseIterable {
    case person = "PERSON"
    case company = "COMPANY"
    case address = "ADDRESS"
    case email = "EMAIL"
    case phone = "PHONE"
    case bankAccount = "BANK_ACCOUNT"
    case nationalID = "NATIONAL_ID"
    case uscc = "USCC"
    case date = "DATE"
    case amount = "AMOUNT"
    case unknown = "UNKNOWN"
}

/// Where a detection came from. Deterministic detections are the trusted,
/// checksum-validated structured PII; llm detections are the fuzzy entities;
/// manual detections are user-supplied additions or corrections.
public enum DetectionSource: String, Codable, Sendable {
    case deterministic
    case llm
    case manual
}

// MARK: - Span

/// A located candidate detection in the source text.
///
/// Offsets are UTF-16 code-unit offsets: start is inclusive, end is exclusive,
/// matching NSRange semantics.
public struct Span: Equatable, Sendable, Codable {
    /// UTF-16 offset, inclusive.
    public var start: Int
    /// UTF-16 offset, exclusive.
    public var end: Int
    /// The classified entity type.
    public var type: EntityType
    /// The exact surface substring covered by this span.
    public var text: String
    /// Where this detection came from.
    public var source: DetectionSource
    /// Detection confidence in the range 0 through 1.
    public var confidence: Double
    /// Overlap-resolution priority. Higher wins. Validated structured PII is
    /// assigned a high priority so deterministic detections win conflicts.
    public var priority: Int

    public init(
        start: Int,
        end: Int,
        type: EntityType,
        text: String,
        source: DetectionSource,
        confidence: Double,
        priority: Int
    ) {
        self.start = start
        self.end = end
        self.type = type
        self.text = text
        self.source = source
        self.confidence = confidence
        self.priority = priority
    }
}

// MARK: - Mapping

/// A single token-to-value mapping entry. One entry per distinct token.
public struct MappingEntry: Equatable, Sendable, Codable {
    /// The opaque token, for example "{PERSON_1}".
    public var token: String
    /// The canonical value to restore for this token.
    public var value: String
    /// The entity type this token represents.
    public var type: EntityType
    /// The exact original surface text this token replaced.
    public var surfaceText: String
    /// Other known surface forms that refer to the same entity.
    public var aliases: [String]

    public init(
        token: String,
        value: String,
        type: EntityType,
        surfaceText: String,
        aliases: [String]
    ) {
        self.token = token
        self.value = value
        self.type = type
        self.surfaceText = surfaceText
        self.aliases = aliases
    }
}

/// The full token map for one tokenization. Pure functions never read the clock,
/// so the caller supplies createdAtISO8601.
public struct Mapping: Equatable, Sendable, Codable {
    /// token -> entry.
    public var entries: [String: MappingEntry]
    /// ISO-8601 creation timestamp supplied by the caller. Do not call Date()
    /// inside pure functions to populate this.
    public var createdAtISO8601: String
    /// The source file this mapping was built from.
    public var sourceFile: String

    public init(
        entries: [String: MappingEntry],
        createdAtISO8601: String,
        sourceFile: String
    ) {
        self.entries = entries
        self.createdAtISO8601 = createdAtISO8601
        self.sourceFile = sourceFile
    }
}

// MARK: - Engine results

/// The result of tokenizing: the tokenized text plus the mapping needed to
/// restore it.
public struct TokenizeResult: Sendable {
    /// The text with surface values replaced by opaque tokens.
    public var tokenizedText: String
    /// The token map built during tokenization.
    public var mapping: Mapping

    public init(tokenizedText: String, mapping: Mapping) {
        self.tokenizedText = tokenizedText
        self.mapping = mapping
    }
}

/// The result of restoring: the restored text, how many tokens were substituted,
/// and any orphan tokens the orphan guard found (tokens present in the text but
/// absent from the mapping, or otherwise leftover or broken).
public struct RestoreResult: Sendable {
    /// The text after token substitution.
    public var text: String
    /// How many tokens were successfully substituted.
    public var restoredCount: Int
    /// Leftover or broken tokens detected by the orphan guard.
    public var orphanTokens: [String]

    public init(text: String, restoredCount: Int, orphanTokens: [String]) {
        self.text = text
        self.restoredCount = restoredCount
        self.orphanTokens = orphanTokens
    }
}

// MARK: - Token grammar

/// The token grammar contract. A token is literally "{TYPE_N}" where TYPE
/// matches [A-Z][A-Z0-9]* and N is a positive integer. Keep emit and restore in
/// sync with placeholderPattern.
public enum TokenGrammar {
    /// Canonical detection regex for a token. Use this on both the emit side and
    /// the restore side so they never drift.
    public static let placeholderPattern = #"\{[A-Z][A-Z0-9]*_\d+\}"#

    /// Sanitize a raw type string into a token TYPE matching [A-Z][A-Z0-9]*.
    ///
    /// Rules:
    /// - Uppercase, then strip every character that is not A-Z or 0-9.
    /// - If the result is empty, return "UNKNOWN".
    /// - If the first character is not A-Z (for example the input was all
    ///   digits), prefix "X" so the token always matches [A-Z][A-Z0-9]*.
    public static func sanitizeType(_ raw: String) -> String {
        let upper = raw.uppercased()
        let allowed = upper.unicodeScalars.filter { scalar in
            (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
        }
        var token = String(String.UnicodeScalarView(allowed))

        if token.isEmpty {
            return "UNKNOWN"
        }

        if let first = token.first, !(first >= "A" && first <= "Z") {
            token = "X" + token
        }

        return token
    }
}

// MARK: - Role labels

/// The denylist of role labels (contract terms of art) that must NEVER be
/// redacted. Matching is case-insensitive and whitespace-trimmed, and covers
/// both English and Chinese role labels.
public enum RoleLabels {
    /// The canonical role-label set, English plus Chinese. Membership tests go
    /// through isRoleLabel, which normalizes case and whitespace.
    public static let all: Set<String> = [
        // English
        "Buyer",
        "Seller",
        "Purchaser",
        "Vendor",
        "Supplier",
        "Lessor",
        "Lessee",
        "Landlord",
        "Tenant",
        "Borrower",
        "Lender",
        "Licensor",
        "Licensee",
        "Guarantor",
        "Disclosing Party",
        "Receiving Party",
        "Employer",
        "Employee",
        "Contractor",
        "Client",
        "Customer",
        "the Company",
        "the Parties",
        "Party A",
        "Party B",
        "Assignor",
        "Assignee",
        "Transferor",
        "Transferee",
        // Financing and corporate party roles (singular and plural, since the
        // model may report either). These are terms of art, not PII.
        "Investor",
        "Investors",
        "Shareholder",
        "Shareholders",
        "Stockholder",
        "Stockholders",
        "Holder",
        "Holders",
        "Noteholder",
        "Noteholders",
        "Subscriber",
        "Subscribers",
        "Founder",
        "Founders",
        "Member",
        "Members",
        "Manager",
        "Managers",
        "Partner",
        "Partners",
        "General Partner",
        "Limited Partner",
        "Sponsor",
        "Issuer",
        "Underwriter",
        "Placement Agent",
        "Trustee",
        "Beneficiary",
        "Pledgor",
        "Pledgee",
        "Mortgagor",
        "Mortgagee",
        "Indemnitor",
        "Indemnitee",
        "Director",
        "Directors",
        "Officer",
        "Officers",
        "Affiliate",
        "Affiliates",
        "Counterparty",
        // Chinese
        "甲方",
        "乙方",
        "丙方",
        "丁方",
        "转让方",
        "受让方",
        "出租方",
        "承租方",
        "出借方",
        "借款方",
        "贷款方",
        "许可方",
        "被许可方",
        "担保方",
        "保证人",
        "卖方",
        "买方",
        "供方",
        "需方",
        "委托方",
        "受托方",
        "出卖人",
        "买受人",
        "转让人",
        "受让人",
        "投资方",
        "投资人",
        "投资者",
        "股东",
        "认购方",
        "认购人",
        "发行人",
        "发行方",
        "持有人",
        "受托人",
        "创始人",
        "合伙人",
        "普通合伙人",
        "有限合伙人"
    ]

    /// Precomputed lowercased, whitespace-trimmed lookup set so membership tests
    /// are case-insensitive without rebuilding the set on every call.
    private static let normalized: Set<String> = Set(
        all.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    )

    /// Returns true when the given string is a known role label. The comparison
    /// trims surrounding whitespace and is case-insensitive.
    public static func isRoleLabel(_ s: String) -> Bool {
        let key = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains(key)
    }
}
