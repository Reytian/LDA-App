//
//  ProfileTypesTests.swift
//  LDACoreTests
//
//  Codable round-trips and derived-state logic for the fill-from-profile
//  domain types.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ProfileTypesTests: XCTestCase {

    private func field(
        key: ProfileFieldKey,
        value: String,
        verified: Bool = true,
        confidence: Double = 0.9
    ) -> ProfileField {
        ProfileField(
            key: key,
            value: value,
            sourceDocument: "cert.pdf",
            sourceSnippet: "snippet containing \(value)",
            snippetVerified: verified,
            confidence: confidence,
            userEdited: false
        )
    }

    func testProfileFieldKeyCanonicalRawValues() {
        XCTAssertEqual(ProfileFieldKey.companyName.rawKey, "companyName")
        XCTAssertEqual(ProfileFieldKey.custom("seal number").rawKey, "custom:seal number")
    }

    func testProfileFieldKeyCodableRoundTripCanonicalAndCustom() throws {
        let keys: [ProfileFieldKey] = [.companyName, .incorporationDate, .custom("seal number")]
        let data = try JSONEncoder().encode(keys)
        let back = try JSONDecoder().decode([ProfileFieldKey].self, from: data)
        XCTAssertEqual(back, keys)
    }

    func testUnknownRawKeyDecodesAsCustomNotError() throws {
        // Forward compatibility: a profile written by a newer build with a new
        // canonical key must still load; it degrades to custom.
        let data = Data("[\"futureKey\"]".utf8)
        let back = try JSONDecoder().decode([ProfileFieldKey].self, from: data)
        XCTAssertEqual(back, [.custom("futureKey")])
    }

    func testClientPortfolioCodableRoundTrip() throws {
        let profile = ClientPortfolio(
            label: "Acme incorporation",
            fields: [field(key: .companyName, value: "Acme Holdings Limited")],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        let data = try JSONEncoder().encode(profile)
        let back = try JSONDecoder().decode(ClientPortfolio.self, from: data)
        XCTAssertEqual(back, profile)
    }

    func testConflictedKeysDerivedForSingleValuedKeyOnly() {
        let profile = ClientPortfolio(
            label: "x",
            fields: [
                field(key: .companyName, value: "Acme Holdings Limited"),
                field(key: .companyName, value: "Acme Holdings (HK) Limited"),
                field(key: .directorName, value: "Jane Roe"),
                field(key: .directorName, value: "John Doe")
            ],
            sourceDocuments: [],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        // companyName is single-valued: two distinct normalized values conflict.
        // directorName is list-like: many values are normal.
        XCTAssertEqual(profile.conflictedKeys, [.companyName])
    }

    func testConflictIgnoresCaseAndWhitespaceDuplicates() {
        let profile = ClientPortfolio(
            label: "x",
            fields: [
                field(key: .companyName, value: "Acme  Holdings Limited"),
                field(key: .companyName, value: "acme holdings limited")
            ],
            sourceDocuments: [],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        XCTAssertEqual(profile.conflictedKeys, [])
    }

    func testBlankCodableRoundTrip() throws {
        // textSpan variant
        let blank = Blank(
            location: .textSpan(start: 10, end: 14),
            label: "Company Name",
            context: "between [Company Name], a company",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .unmatched
        )
        let data = try JSONEncoder().encode(blank)
        let back = try JSONDecoder().decode(Blank.self, from: data)
        XCTAssertEqual(back, blank)

        // acroFormField variant
        let blank2 = Blank(
            location: .acroFormField(name: "CompanyName"),
            label: "CompanyName",
            context: "",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .proposed
        )
        let data2 = try JSONEncoder().encode(blank2)
        let back2 = try JSONDecoder().decode(Blank.self, from: data2)
        XCTAssertEqual(back2, blank2)
    }

    func testFillReportCodableRoundTrip() throws {
        let report = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/out.docx"),
            filledCount: 3,
            skipped: [SkippedBlank(label: "Fax", locationDescription: "field Fax", reason: "no matching field")]
        )
        let rdata = try JSONEncoder().encode(report)
        let rback = try JSONDecoder().decode(FillReport.self, from: rdata)
        XCTAssertEqual(rback, report)
    }

    func testBlankDecodesWithoutCandidateFieldIDsForBackwardCompat() throws {
        // Legacy JSON blobs written before candidateFieldIDs was added must still
        // decode without error and must produce candidateFieldIDs == nil.
        // The Blank decoder uses decodeIfPresent for that key, so absence of the
        // key is not an error.
        let legacyUUID = UUID()
        let legacyJSON = """
        {
            "id": "\(legacyUUID.uuidString)",
            "location": {"textSpan": {"start": 5, "end": 10}},
            "label": "Company Name",
            "context": "between [Company Name], a company",
            "status": "unmatched"
        }
        """
        let data = Data(legacyJSON.utf8)
        let blank = try JSONDecoder().decode(Blank.self, from: data)
        XCTAssertEqual(blank.id, legacyUUID)
        XCTAssertEqual(blank.label, "Company Name")
        XCTAssertEqual(blank.context, "between [Company Name], a company")
        XCTAssertEqual(blank.status, .unmatched)
        XCTAssertNil(blank.candidateFieldIDs,
                     "candidateFieldIDs must be nil when the key is absent in legacy JSON")
    }

    func testFillPlanCodableRoundTrip() throws {
        let blank = Blank(
            location: .textSpan(start: 0, end: 4),
            label: "Party",
            context: "[Party] agrees",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .proposed
        )
        let plan = FillPlan(
            targetFormat: .docx,
            blanks: [blank],
            manualWidgetNames: ["Agree"]
        )
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(FillPlan.self, from: data)
        XCTAssertEqual(back, plan)
    }

    // MARK: - ClientPortfolio / PortfolioKind / new canonical keys

    func testPortfolioKindDecodeDefaultsToCompany() throws {
        // Legacy JSON written before kind existed.
        let legacy = """
        {"label":"Acme","fields":[],"sourceDocuments":[],"createdAtISO8601":"2026-06-10T00:00:00Z","incomplete":false}
        """.data(using: .utf8)!
        let portfolio = try JSONDecoder().decode(ClientPortfolio.self, from: legacy)
        XCTAssertEqual(portfolio.kind, .company)
        XCTAssertEqual(portfolio.modifiedAtISO8601, "2026-06-10T00:00:00Z")
    }

    func testKindAndModifiedAtRoundTrip() throws {
        var portfolio = ClientPortfolio(
            label: "Jane", fields: [], sourceDocuments: [],
            createdAtISO8601: "2026-06-11T00:00:00Z", incomplete: false
        )
        portfolio.kind = .individual
        portfolio.modifiedAtISO8601 = "2026-06-11T01:00:00Z"
        let back = try JSONDecoder().decode(ClientPortfolio.self, from: JSONEncoder().encode(portfolio))
        XCTAssertEqual(back.kind, .individual)
        XCTAssertEqual(back.modifiedAtISO8601, "2026-06-11T01:00:00Z")
    }

    func testCanonicalForKind() {
        let company = ProfileFieldKey.canonical(for: .company)
        XCTAssertTrue(company.contains(.companyName))
        XCTAssertTrue(company.contains(.email))
        XCTAssertTrue(company.contains(.phone))
        XCTAssertFalse(company.contains(.passportNumber))
        let individual = ProfileFieldKey.canonical(for: .individual)
        XCTAssertEqual(individual, [.clientName, .dateOfBirth, .nationality, .passportNumber,
                                    .nationalIDNumber, .residentialAddress, .email, .phone])
        let general = ProfileFieldKey.canonical(for: .general)
        XCTAssertEqual(Set(general), Set(company).union(individual))
    }

    func testNewSingleValuedKeysConflict() {
        let a = ProfileField(key: .passportNumber, value: "E12345678", sourceDocument: "p.pdf",
                             sourceSnippet: "E12345678", snippetVerified: true, confidence: 0.9, userEdited: false)
        let b = ProfileField(key: .passportNumber, value: "E87654321", sourceDocument: "p2.pdf",
                             sourceSnippet: "E87654321", snippetVerified: true, confidence: 0.9, userEdited: false)
        let portfolio = ClientPortfolio(label: "x", fields: [a, b], sourceDocuments: [],
                                        createdAtISO8601: "2026-06-11T00:00:00Z", incomplete: false)
        XCTAssertEqual(portfolio.conflictedKeys, [.passportNumber])
    }

    func testNewKeysRawKeyRoundTrip() throws {
        let keys: [ProfileFieldKey] = [.clientName, .dateOfBirth, .nationality, .passportNumber,
                                       .nationalIDNumber, .residentialAddress, .email, .phone]
        let back = try JSONDecoder().decode([ProfileFieldKey].self, from: JSONEncoder().encode(keys))
        XCTAssertEqual(back, keys)
    }

    // MARK: - Design-decision: conflict detection is data-scoped, not kind-scoped

    func testConflictDetectionIsDataScopedNotKindScoped() {
        // A .company-kind portfolio that happens to hold two different passportNumber
        // values still has a real data inconsistency (two distinct single-valued facts
        // for the same key). conflictedKeys must surface it regardless of kind.
        // This test pins the design decision that conflict detection covers ALL
        // single-valued canonical keys the portfolio holds, not just the keys that
        // are "expected" for the portfolio's kind.
        let a = ProfileField(key: .passportNumber, value: "A12345678",
                             sourceDocument: "corp.pdf", sourceSnippet: "A12345678",
                             snippetVerified: true, confidence: 0.9, userEdited: false)
        let b = ProfileField(key: .passportNumber, value: "B99999999",
                             sourceDocument: "corp.pdf", sourceSnippet: "B99999999",
                             snippetVerified: true, confidence: 0.9, userEdited: false)
        let portfolio = ClientPortfolio(
            label: "Acme Corp",
            fields: [a, b],
            sourceDocuments: ["corp.pdf"],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false,
            kind: .company
        )
        XCTAssertEqual(portfolio.kind, .company, "sanity: portfolio is company-kind")
        XCTAssertTrue(portfolio.conflictedKeys.contains(.passportNumber),
                      "passportNumber conflict must appear even in a company-kind portfolio")
    }

    func testInitErgonomicsKindParameter() {
        // Verify the new convenience parameters: kind is set directly on init,
        // and modifiedAtISO8601 falls back to createdAtISO8601 when nil.
        let created = "2026-06-11T00:00:00Z"
        let portfolio = ClientPortfolio(
            label: "Jane Doe",
            fields: [],
            sourceDocuments: [],
            createdAtISO8601: created,
            incomplete: false,
            kind: .individual
        )
        XCTAssertEqual(portfolio.kind, .individual)
        XCTAssertEqual(portfolio.modifiedAtISO8601, created,
                       "modifiedAtISO8601 must default to createdAtISO8601 when nil is passed")
    }
}
