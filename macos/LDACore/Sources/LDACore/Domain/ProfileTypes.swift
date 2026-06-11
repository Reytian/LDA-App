//
//  ProfileTypes.swift
//  LDACore
//
//  Frozen public domain types for the fill-from-profile feature: the extracted
//  Client Portfolio, detected blanks in a fill target, the fill plan, and the
//  value-free fill report.
//
//  Offset convention: BlankLocation.textSpan offsets are UTF-16 code units into
//  ImportedDocument.text, NSRange-compatible, matching Span in CoreTypes.swift.
//
//  Conflict state is DERIVED, never stored: a single-valued key holding more
//  than one distinct normalized value is in conflict (see conflictedKeys).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - PortfolioKind

/// Classifies the subject of a ClientPortfolio: a corporate entity, a natural
/// person, or a general-purpose portfolio that covers both field sets.
public enum PortfolioKind: String, Codable, Sendable, CaseIterable {
    case company
    case individual
    case general
}

// MARK: - ProfileFieldKey

/// The canonical fact kinds a Client Portfolio can hold, plus a custom escape
/// hatch for anything else the model finds worth keeping. Codable as a plain
/// string; unknown canonical strings decode as .custom for forward
/// compatibility.
public enum ProfileFieldKey: Hashable, Sendable {
    // Company keys (original 17)
    case companyName
    case companyNameLocal
    case formerName
    case entityKind
    case jurisdiction
    case companyNumber
    case incorporationDate
    case registeredOffice
    case authorizedCapital
    case issuedCapital
    case parValue
    case shareClass
    case directorName
    case shareholderName
    case shareholderShares
    case companySecretary
    case registeredAgent
    // Individual keys (8 new)
    case clientName
    case dateOfBirth
    case nationality
    case passportNumber
    case nationalIDNumber
    case residentialAddress
    case email
    case phone
    case custom(String)

    /// The canonical cases in stable order for company profiles (17 original
    /// keys), excluding custom.
    public static let canonical: [ProfileFieldKey] = [
        .companyName, .companyNameLocal, .formerName, .entityKind,
        .jurisdiction, .companyNumber, .incorporationDate, .registeredOffice,
        .authorizedCapital, .issuedCapital, .parValue, .shareClass,
        .directorName, .shareholderName, .shareholderShares,
        .companySecretary, .registeredAgent,
        .clientName, .dateOfBirth, .nationality, .passportNumber,
        .nationalIDNumber, .residentialAddress, .email, .phone
    ]

    /// The canonical keys for a given portfolio kind, in stable order.
    /// company: the original 17 corporate keys plus email and phone.
    /// individual: the 8 person-specific keys.
    /// general: the company list followed by any individual keys not already present.
    public static func canonical(for kind: PortfolioKind) -> [ProfileFieldKey] {
        let companyKeys: [ProfileFieldKey] = [
            .companyName, .companyNameLocal, .formerName, .entityKind,
            .jurisdiction, .companyNumber, .incorporationDate, .registeredOffice,
            .authorizedCapital, .issuedCapital, .parValue, .shareClass,
            .directorName, .shareholderName, .shareholderShares,
            .companySecretary, .registeredAgent, .email, .phone
        ]
        let individualKeys: [ProfileFieldKey] = [
            .clientName, .dateOfBirth, .nationality, .passportNumber,
            .nationalIDNumber, .residentialAddress, .email, .phone
        ]
        switch kind {
        case .company:
            return companyKeys
        case .individual:
            return individualKeys
        case .general:
            let companySet = Set(companyKeys)
            let extra = individualKeys.filter { !companySet.contains($0) }
            return companyKeys + extra
        }
    }

    /// Keys that may legitimately hold several distinct values.
    public static let listLike: Set<ProfileFieldKey> = [
        .formerName, .shareClass, .directorName, .shareholderName,
        .shareholderShares
    ]

    /// Used by init(rawKey:) for decoding only. Not used for encoding.
    private static let canonicalRaw: [String: ProfileFieldKey] = [
        "companyName": .companyName,
        "companyNameLocal": .companyNameLocal,
        "formerName": .formerName,
        "entityKind": .entityKind,
        "jurisdiction": .jurisdiction,
        "companyNumber": .companyNumber,
        "incorporationDate": .incorporationDate,
        "registeredOffice": .registeredOffice,
        "authorizedCapital": .authorizedCapital,
        "issuedCapital": .issuedCapital,
        "parValue": .parValue,
        "shareClass": .shareClass,
        "directorName": .directorName,
        "shareholderName": .shareholderName,
        "shareholderShares": .shareholderShares,
        "companySecretary": .companySecretary,
        "registeredAgent": .registeredAgent,
        "clientName": .clientName,
        "dateOfBirth": .dateOfBirth,
        "nationality": .nationality,
        "passportNumber": .passportNumber,
        "nationalIDNumber": .nationalIDNumber,
        "residentialAddress": .residentialAddress,
        "email": .email,
        "phone": .phone
    ]

    /// The stable wire string. Canonical keys use their name; custom keys are
    /// prefixed so they can never collide with a future canonical key.
    /// Exhaustive switch gives compile-time completeness: adding a new canonical
    /// case without updating this switch is a build error.
    public var rawKey: String {
        switch self {
        case .companyName: return "companyName"
        case .companyNameLocal: return "companyNameLocal"
        case .formerName: return "formerName"
        case .entityKind: return "entityKind"
        case .jurisdiction: return "jurisdiction"
        case .companyNumber: return "companyNumber"
        case .incorporationDate: return "incorporationDate"
        case .registeredOffice: return "registeredOffice"
        case .authorizedCapital: return "authorizedCapital"
        case .issuedCapital: return "issuedCapital"
        case .parValue: return "parValue"
        case .shareClass: return "shareClass"
        case .directorName: return "directorName"
        case .shareholderName: return "shareholderName"
        case .shareholderShares: return "shareholderShares"
        case .companySecretary: return "companySecretary"
        case .registeredAgent: return "registeredAgent"
        case .clientName: return "clientName"
        case .dateOfBirth: return "dateOfBirth"
        case .nationality: return "nationality"
        case .passportNumber: return "passportNumber"
        case .nationalIDNumber: return "nationalIDNumber"
        case .residentialAddress: return "residentialAddress"
        case .email: return "email"
        case .phone: return "phone"
        case .custom(let name): return "custom:\(name)"
        }
    }

    /// Resolve a wire string. Unknown strings become .custom(raw) so profiles
    /// written by newer builds still load.
    public init(rawKey: String) {
        if rawKey.hasPrefix("custom:") {
            self = .custom(String(rawKey.dropFirst("custom:".count)))
        } else if let canonical = ProfileFieldKey.canonicalRaw[rawKey] {
            self = canonical
        } else {
            self = .custom(rawKey)
        }
    }

    /// A short human label for UI and CLI output.
    public var displayName: String {
        switch self {
        case .companyName: return "Company name"
        case .companyNameLocal: return "Company name (local language)"
        case .formerName: return "Former name"
        case .entityKind: return "Entity kind"
        case .jurisdiction: return "Jurisdiction"
        case .companyNumber: return "Company number"
        case .incorporationDate: return "Incorporation date"
        case .registeredOffice: return "Registered office"
        case .authorizedCapital: return "Authorized capital"
        case .issuedCapital: return "Issued capital"
        case .parValue: return "Par value"
        case .shareClass: return "Share class"
        case .directorName: return "Director"
        case .shareholderName: return "Shareholder"
        case .shareholderShares: return "Shareholder shares"
        case .companySecretary: return "Company secretary"
        case .registeredAgent: return "Registered agent"
        case .clientName: return "Client name"
        case .dateOfBirth: return "Date of birth"
        case .nationality: return "Nationality"
        case .passportNumber: return "Passport number"
        case .nationalIDNumber: return "National ID number"
        case .residentialAddress: return "Residential address"
        case .email: return "Email"
        case .phone: return "Phone"
        case .custom(let name): return name
        }
    }
}

extension ProfileFieldKey: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawKey: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawKey)
    }
}

// MARK: - ProfileField

/// One extracted fact with provenance. sourceSnippet is the verbatim line or
/// sentence the value came from; snippetVerified is true only when that
/// snippet was located verbatim (case-insensitive) in the imported source
/// text.
public struct ProfileField: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var key: ProfileFieldKey
    public var value: String
    public var sourceDocument: String
    public var sourceSnippet: String
    public var snippetVerified: Bool
    /// LLM extraction confidence in [0, 1]. The memberwise init clamps any
    /// out-of-range value supplied by the caller.
    public var confidence: Double
    public var userEdited: Bool

    public init(
        id: UUID = UUID(),
        key: ProfileFieldKey,
        value: String,
        sourceDocument: String,
        sourceSnippet: String,
        snippetVerified: Bool,
        confidence: Double,
        userEdited: Bool
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.sourceDocument = sourceDocument
        self.sourceSnippet = sourceSnippet
        self.snippetVerified = snippetVerified
        self.confidence = min(1, max(0, confidence))
        self.userEdited = userEdited
    }

    /// Normalization used for dedupe and conflict detection: case folded,
    /// whitespace collapsed.
    public var normalizedValue: String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - ClientPortfolio

/// The reviewed, persistable portfolio for any client type (company,
/// individual, or general). createdAtISO8601 is supplied by the caller per
/// the purity rule. incomplete mirrors the LJE-001 posture: true when any
/// extraction segment was truncated, so fields may be missing.
///
/// kind and modifiedAtISO8601 were added after the initial release. Legacy
/// JSON without these keys decodes with kind = .company and modifiedAt equal
/// to createdAt (backward compatible).
public struct ClientPortfolio: Equatable, Sendable {
    public var label: String
    /// Field order is significant for Equatable comparisons.
    public var fields: [ProfileField]
    public var sourceDocuments: [String]
    public var createdAtISO8601: String
    public var incomplete: Bool
    /// The subject kind. Defaults to .company for legacy data.
    public var kind: PortfolioKind
    /// Last modification timestamp (ISO 8601). Defaults to createdAtISO8601
    /// for legacy data.
    public var modifiedAtISO8601: String

    public init(
        label: String,
        fields: [ProfileField],
        sourceDocuments: [String],
        createdAtISO8601: String,
        incomplete: Bool
    ) {
        self.label = label
        self.fields = fields
        self.sourceDocuments = sourceDocuments
        self.createdAtISO8601 = createdAtISO8601
        self.incomplete = incomplete
        self.kind = .company
        self.modifiedAtISO8601 = createdAtISO8601
    }

    /// Single-valued keys currently holding more than one distinct normalized
    /// value. Derived at call time; nothing is stored.
    public var conflictedKeys: [ProfileFieldKey] {
        var valuesByKey: [ProfileFieldKey: Set<String>] = [:]
        for field in fields where !ProfileFieldKey.listLike.contains(field.key) {
            if case .custom = field.key { continue }
            valuesByKey[field.key, default: []].insert(field.normalizedValue)
        }
        return ProfileFieldKey.canonical.filter { (valuesByKey[$0]?.count ?? 0) > 1 }
    }
}

extension ClientPortfolio: Codable {
    private enum CodingKeys: String, CodingKey {
        case label, fields, sourceDocuments, createdAtISO8601, incomplete
        case kind, modifiedAtISO8601
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        fields = try c.decode([ProfileField].self, forKey: .fields)
        sourceDocuments = try c.decode([String].self, forKey: .sourceDocuments)
        createdAtISO8601 = try c.decode(String.self, forKey: .createdAtISO8601)
        incomplete = try c.decode(Bool.self, forKey: .incomplete)
        // New optional fields: default to company / createdAt for legacy JSON.
        kind = try c.decodeIfPresent(PortfolioKind.self, forKey: .kind) ?? .company
        modifiedAtISO8601 = try c.decodeIfPresent(String.self, forKey: .modifiedAtISO8601) ?? createdAtISO8601
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(fields, forKey: .fields)
        try c.encode(sourceDocuments, forKey: .sourceDocuments)
        try c.encode(createdAtISO8601, forKey: .createdAtISO8601)
        try c.encode(incomplete, forKey: .incomplete)
        try c.encode(kind, forKey: .kind)
        try c.encode(modifiedAtISO8601, forKey: .modifiedAtISO8601)
    }
}

// MARK: - Blank

/// Where a blank lives in the fill target.
public enum BlankLocation: Hashable, Equatable, Sendable, Codable {
    /// UTF-16 offsets into the imported target text (NSRange semantics).
    case textSpan(start: Int, end: Int)
    /// The AcroForm field name of a text widget.
    case acroFormField(name: String)
}

/// Review status of one blank.
public enum BlankStatus: String, Equatable, Sendable, Codable {
    case proposed
    case confirmed
    case rejected
    case unmatched
}

/// One detected blank, its label and context, and the proposed fill.
public struct Blank: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var location: BlankLocation
    /// The bracket contents, handlebars name, or AcroForm field name. Empty
    /// for bare underscore and dot placeholders.
    public var label: String
    /// Text window around the blank, for matching and for the review UI.
    public var context: String
    /// The ProfileField.id this blank is proposed to take its value from.
    public var proposedFieldID: UUID?
    /// The value that would be written. Defaults to the field's canonical
    /// value; the planner may propose a format adaptation, which review shows
    /// beside the verbatim profile value.
    public var proposedValue: String?
    public var status: BlankStatus
    /// Set by FillPlanner for ambiguous synonym hits: the IDs of every profile
    /// field whose key matched. Nil for unambiguous matches and unmatched blanks.
    /// Decoded with decodeIfPresent so profiles written before this field was
    /// added still load (backward compatible).
    public var candidateFieldIDs: [UUID]?

    public init(
        id: UUID = UUID(),
        location: BlankLocation,
        label: String,
        context: String,
        proposedFieldID: UUID?,
        proposedValue: String?,
        status: BlankStatus,
        candidateFieldIDs: [UUID]? = nil
    ) {
        self.id = id
        self.location = location
        self.label = label
        self.context = context
        self.proposedFieldID = proposedFieldID
        self.proposedValue = proposedValue
        self.status = status
        self.candidateFieldIDs = candidateFieldIDs
    }

    // MARK: - Codable (manual to support backward-compatible decoding)

    private enum CodingKeys: String, CodingKey {
        case id, location, label, context
        case proposedFieldID, proposedValue, status
        case candidateFieldIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        location = try c.decode(BlankLocation.self, forKey: .location)
        label = try c.decode(String.self, forKey: .label)
        context = try c.decode(String.self, forKey: .context)
        proposedFieldID = try c.decodeIfPresent(UUID.self, forKey: .proposedFieldID)
        proposedValue = try c.decodeIfPresent(String.self, forKey: .proposedValue)
        status = try c.decode(BlankStatus.self, forKey: .status)
        candidateFieldIDs = try c.decodeIfPresent([UUID].self, forKey: .candidateFieldIDs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(location, forKey: .location)
        try c.encode(label, forKey: .label)
        try c.encode(context, forKey: .context)
        try c.encodeIfPresent(proposedFieldID, forKey: .proposedFieldID)
        try c.encodeIfPresent(proposedValue, forKey: .proposedValue)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(candidateFieldIDs, forKey: .candidateFieldIDs)
    }
}

// MARK: - FillPlan

/// The reviewable plan for one target document.
public struct FillPlan: Equatable, Sendable, Codable {
    public var targetFormat: DocumentFormat
    public var blanks: [Blank]
    /// AcroForm widgets V1 will not auto-fill (checkbox, radio, choice),
    /// surfaced so the report can list them as manual items.
    public var manualWidgetNames: [String]

    public init(targetFormat: DocumentFormat, blanks: [Blank], manualWidgetNames: [String] = []) {
        self.targetFormat = targetFormat
        self.blanks = blanks
        self.manualWidgetNames = manualWidgetNames
    }
}

// MARK: - FillReport

/// A skipped blank, described without its value.
public struct SkippedBlank: Equatable, Sendable, Codable {
    public var label: String
    public var locationDescription: String
    public var reason: String

    public init(label: String, locationDescription: String, reason: String) {
        self.label = label
        self.locationDescription = locationDescription
        self.reason = reason
    }
}

/// The value-free outcome of an apply run. Value-free means no filled values
/// appear anywhere in this struct: filledCount is a count, skipped entries
/// describe location and reason but never the proposed fill value. This
/// guarantee is intentional so that the report can be displayed and printed
/// without risk of leaking PII from the profile. LDA never persists the
/// report to disk. outputURL is the user-chosen local output path; the user
/// already knows it and it is recorded here only for display in the review UI.
public struct FillReport: Equatable, Sendable, Codable {
    public var outputURL: URL
    public var filledCount: Int
    public var skipped: [SkippedBlank]

    public init(outputURL: URL, filledCount: Int, skipped: [SkippedBlank]) {
        self.outputURL = outputURL
        self.filledCount = filledCount
        self.skipped = skipped
    }
}
