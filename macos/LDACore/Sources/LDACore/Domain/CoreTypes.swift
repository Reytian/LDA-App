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
    case caseNumber = "CASE_NUMBER"
    case licensePlate = "LICENSE_PLATE"
    case wechatID = "WECHAT_ID"
    case url = "URL"
    case seal = "SEAL"
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

// MARK: - Substitution style

/// How detected entities are rendered in the redacted output.
///
/// Part of the persisted Mapping wire format: restore dispatches on the
/// style stored in the sidecar, so a mapping always knows how to find its
/// own replacements.
public enum SubstitutionStyle: String, Codable, Sendable, CaseIterable {
    /// Opaque brace tokens, "{TYPE_N}". The historical default. Restore is a
    /// grammar scan; byte-identical round trip for well-formed tokens, but an
    /// external AI often rewrites the braces and breaks the token.
    case token
    /// Natural-language stand-ins (甲公司, 张某, Company A). An external AI
    /// treats them as names, not markup, so they survive AI round trips.
    /// Restore is a literal scan of the mapping's replacement strings.
    case pseudonym
    /// Lossy per-type masking (张*明, 138****5678) for documents sent to
    /// human readers. Restore substitutes only unambiguous masks; colliding
    /// masks are flagged and never guessed.
    case asterisk
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
    /// When this entry is a defined short name of another entry's entity
    /// (全称/简称归并), the canonical entry's KEY in Mapping.entries, for
    /// example "{COMPANY_2}". The key is chosen over the entry's token field
    /// deliberately: keys are unique, while asterisk-collision entries store
    /// a shared mask in token and disambiguate the key ("张*#2"), so a key
    /// reference always resolves to exactly one entry.
    /// The alias keeps its OWN token and value so restore stays byte-identical
    /// at every site; this field only records the grouping. Nil for canonical
    /// entries and for entries with no known alias relationship. Optional and
    /// absent from older sidecars, which decode as nil.
    public var canonicalToken: String?

    public init(
        token: String,
        value: String,
        type: EntityType,
        surfaceText: String,
        aliases: [String],
        canonicalToken: String? = nil
    ) {
        self.token = token
        self.value = value
        self.type = type
        self.surfaceText = surfaceText
        self.aliases = aliases
        self.canonicalToken = canonicalToken
    }
}

/// The full token map for one tokenization. Pure functions never read the clock,
/// so the caller supplies createdAtISO8601.
public struct Mapping: Equatable, Sendable, Codable {
    /// key -> entry. The key equals the entry's token for the token and
    /// pseudonym styles (replacements are unique there). Asterisk masks can
    /// collide across entities, so a colliding entry is stored under a
    /// disambiguated key while its token keeps the shared replacement string.
    public var entries: [String: MappingEntry]
    /// ISO-8601 creation timestamp supplied by the caller. Do not call Date()
    /// inside pure functions to populate this.
    public var createdAtISO8601: String
    /// The source file this mapping was built from.
    public var sourceFile: String
    /// The substitution style this mapping's replacements were rendered in.
    /// Sidecars written before styles existed have no style field and decode
    /// as .token, preserving their historical restore behavior.
    public var style: SubstitutionStyle

    public init(
        entries: [String: MappingEntry],
        createdAtISO8601: String,
        sourceFile: String,
        style: SubstitutionStyle = .token
    ) {
        self.entries = entries
        self.createdAtISO8601 = createdAtISO8601
        self.sourceFile = sourceFile
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case createdAtISO8601
        case sourceFile
        case style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try container.decode([String: MappingEntry].self, forKey: .entries)
        self.createdAtISO8601 = try container.decode(String.self, forKey: .createdAtISO8601)
        self.sourceFile = try container.decode(String.self, forKey: .sourceFile)
        // Legacy payloads predate styles; they are token-style by definition.
        self.style = try container.decodeIfPresent(SubstitutionStyle.self, forKey: .style) ?? .token
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
    /// Per-style orphan report. Token style: token-shaped strings present in
    /// the text but absent from the mapping (leftover or broken tokens).
    /// Pseudonym and asterisk styles: mapping replacements that were never
    /// substituted because the text no longer contains them.
    public var orphanTokens: [String]
    /// Near-miss placeholder shapes found by the forensics scan: strings that
    /// look like a mangled session placeholder (bracket swap, lost brace, case
    /// or space damage, bare TYPE_N, or separator drift in a known TYPE name
    /// such as "{BANK_ACCOUNT_1}" for BANKACCOUNT or "{PERSON1}"). These are
    /// flagged for the user and NEVER substituted, per the flag-don't-guess
    /// contract. Token style only.
    public var suspectPlaceholders: [String]
    /// Asterisk style only: masked forms shared by two or more different
    /// entities. Substituting one would be a guess, so those sites are left
    /// verbatim and reported here (flag, never guess).
    public var ambiguousReplacements: [String]

    public init(
        text: String,
        restoredCount: Int,
        orphanTokens: [String],
        suspectPlaceholders: [String] = [],
        ambiguousReplacements: [String] = []
    ) {
        self.text = text
        self.restoredCount = restoredCount
        self.orphanTokens = orphanTokens
        self.suspectPlaceholders = suspectPlaceholders
        self.ambiguousReplacements = ambiguousReplacements
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

    /// Whether an entire string is one placeholder-shaped token. Used to tell
    /// brace entries from replacements carried across substitution styles.
    public static func isPlaceholderShaped(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        guard let regex = try? NSRegularExpression(pattern: "^\(placeholderPattern)$") else {
            return false
        }
        return regex.firstMatch(in: s, range: range) != nil
    }

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
