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

    func testCompanyProfileCodableRoundTrip() throws {
        let profile = CompanyProfile(
            label: "Acme incorporation",
            fields: [field(key: .companyName, value: "Acme Holdings Limited")],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
        let data = try JSONEncoder().encode(profile)
        let back = try JSONDecoder().decode(CompanyProfile.self, from: data)
        XCTAssertEqual(back, profile)
    }

    func testConflictedKeysDerivedForSingleValuedKeyOnly() {
        let profile = CompanyProfile(
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
        let profile = CompanyProfile(
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
}
