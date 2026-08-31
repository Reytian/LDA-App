//
//  ComplianceReportTests.swift
//  LDACoreTests
//
//  Tests for the compliance processing report: the optional SessionRecord
//  fields (substitution style, model name, app version, scan verification)
//  and the pure Markdown generator. The generator takes a SessionRecord and
//  caller-supplied scalars ONLY, so a report can never leak entity plaintext
//  or mapping values by construction.
//
//  Hermetic: temp directories and passphrase protection throughout.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

// MARK: - Record field tests

final class SessionRecordComplianceFieldsTests: XCTestCase {

    private var root: URL!
    private var store: SessionRecordStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SessionRecordComplianceFieldsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        store = try SessionRecordStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFullRecord() -> SessionRecord {
        SessionRecord(
            createdAtISO8601: "2026-08-30T10:00:00Z",
            clientLabel: "Acme Matter",
            documents: [
                SessionRecordDocument(
                    name: "a.docx",
                    entityCount: 3,
                    entityTypes: ["EMAIL", "PERSON"],
                    entityCountsByType: ["EMAIL": 1, "PERSON": 2]
                )
            ],
            protectedValueCount: 3,
            restoreEvents: [],
            substitutionStyle: .pseudonym,
            modelName: "Qwen3.5-4B-Instruct",
            appVersion: "1.4.0",
            scanVerification: SessionScanVerification(
                rescanHitCount: 2,
                rescanWarningCount: 0,
                forensicsSuspectCount: 1
            )
        )
    }

    /// A record written before the compliance fields existed must decode with
    /// every new field absent. The JSON mirrors what the old encoder wrote.
    func testOldFormatRecordJSONDecodesWithNilComplianceFields() throws {
        let oldJSON = """
        {
          "clientLabel": "Old Matter",
          "createdAtISO8601": "2026-06-11T00:00:00Z",
          "documents": [
            {
              "entityCount": 2,
              "entityTypes": ["EMAIL", "PERSON"],
              "name": "old.txt"
            }
          ],
          "id": "11111111-2222-3333-4444-555555555555",
          "protectedValueCount": 2,
          "restoreEvents": []
        }
        """

        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(oldJSON.utf8))

        XCTAssertEqual(record.clientLabel, "Old Matter")
        XCTAssertEqual(record.documents.map(\.name), ["old.txt"])
        XCTAssertEqual(record.protectedValueCount, 2)
        XCTAssertNil(record.substitutionStyle)
        XCTAssertNil(record.modelName)
        XCTAssertNil(record.appVersion)
        XCTAssertNil(record.scanVerification)
        XCTAssertNil(record.documents[0].entityCountsByType)
    }

    func testComplianceFieldsSurviveEncodeDecodeRoundTrip() throws {
        let record = makeFullRecord()

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.substitutionStyle, .pseudonym)
        XCTAssertEqual(decoded.modelName, "Qwen3.5-4B-Instruct")
        XCTAssertEqual(decoded.appVersion, "1.4.0")
        XCTAssertEqual(
            decoded.scanVerification,
            SessionScanVerification(rescanHitCount: 2, rescanWarningCount: 0, forensicsSuspectCount: 1)
        )
        XCTAssertEqual(decoded.documents[0].entityCountsByType, ["EMAIL": 1, "PERSON": 2])
    }

    func testStoreRoundTripsComplianceFields() throws {
        let record = makeFullRecord()
        try store.save(record, protection: .passphrase("pw"))

        let loaded = try store.load(id: record.id, protection: .passphrase("pw"))

        XCTAssertEqual(loaded, record)
    }

    func testUpdateScanVerificationStampsExistingRecord() throws {
        var record = makeFullRecord()
        record.scanVerification = nil
        try store.save(record, protection: .passphrase("pw"))

        let verification = SessionScanVerification(
            rescanHitCount: 5,
            rescanWarningCount: 1,
            forensicsSuspectCount: 0
        )
        try store.updateScanVerification(
            to: record.id,
            verification: verification,
            protection: .passphrase("pw")
        )

        let loaded = try store.load(id: record.id, protection: .passphrase("pw"))
        XCTAssertEqual(loaded?.scanVerification, verification)
    }

    func testUpdateScanVerificationIsANoOpForMissingRecord() throws {
        XCTAssertNoThrow(
            try store.updateScanVerification(
                to: UUID(),
                verification: SessionScanVerification(
                    rescanHitCount: 0,
                    rescanWarningCount: 0,
                    forensicsSuspectCount: 0
                ),
                protection: .passphrase("pw")
            )
        )
    }
}

// MARK: - Markdown generator tests

final class ComplianceReportTests: XCTestCase {

    private static let generatedAt = "2026-08-31T09:00:00Z"

    /// The fixed full fixture behind the exact snapshot test.
    private func makeFullRecord() -> SessionRecord {
        SessionRecord(
            id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEFFFF0001")!,
            createdAtISO8601: "2026-08-30T10:00:00Z",
            clientLabel: "Matter 2026-104",
            documents: [
                SessionRecordDocument(
                    name: "contract.docx",
                    entityCount: 5,
                    entityTypes: ["PERSON", "COMPANY", "EMAIL"],
                    entityCountsByType: ["PERSON": 2, "COMPANY": 2, "EMAIL": 1]
                ),
                SessionRecordDocument(
                    name: "complaint.pdf",
                    entityCount: 2,
                    entityTypes: ["NATIONAL_ID"],
                    entityCountsByType: ["NATIONAL_ID": 2]
                )
            ],
            protectedValueCount: 6,
            restoreEvents: [
                SessionRestoreEvent(
                    atISO8601: "2026-08-30T11:30:00Z",
                    restoredCount: 6,
                    orphanCount: 0,
                    suspectCount: 1
                )
            ],
            substitutionStyle: .pseudonym,
            modelName: "Qwen3.5-4B-Instruct",
            appVersion: "1.4.0",
            scanVerification: SessionScanVerification(
                rescanHitCount: 3,
                rescanWarningCount: 0,
                forensicsSuspectCount: 0
            )
        )
    }

    /// A record exactly as an old build would have written it: no style, no
    /// model, no version, no scan verification, no per-type counts.
    private func makeOldFormatRecord() -> SessionRecord {
        SessionRecord(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAtISO8601: "2026-06-11T00:00:00Z",
            clientLabel: nil,
            documents: [
                SessionRecordDocument(name: "old.txt", entityCount: 2, entityTypes: ["EMAIL", "PERSON"])
            ],
            protectedValueCount: 2
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testFullRecordRendersExactMarkdown() {
        let expected = """
        # Anonymization Processing Report

        Generated at 2026-08-31T09:00:00Z by LDA (Legal Document Anonymizer).

        ## Session

        | Field | Value |
        | --- | --- |
        | Session ID | AAAAAAAA-BBBB-4CCC-8DDD-EEEEFFFF0001 |
        | Session created | 2026-08-30T10:00:00Z |
        | Client label | Matter 2026-104 |
        | App version | 1.4.0 |
        | Detection model | Qwen3.5-4B-Instruct |
        | Substitution style | Natural language pseudonyms |
        | Distinct protected identities | 6 |

        ## Documents

        | Document | Protected entities | Entity types |
        | --- | --- | --- |
        | contract.docx | 5 | PERSON: 2, COMPANY: 2, EMAIL: 1 |
        | complaint.pdf | 2 | NATIONAL_ID: 2 |

        ## Verification

        ### Scan verification

        | Check | Count |
        | --- | --- |
        | Literal rescan hits | 3 |
        | Open cross-document rescan warnings | 0 |
        | Placeholder forensics suspects | 0 |

        ### Restore events

        | Restored at | Restored | Orphan placeholders | Suspect placeholders |
        | --- | --- | --- | --- |
        | 2026-08-30T11:30:00Z | 6 | 0 | 1 |

        ## Scope and boundary

        This report was generated from the encrypted session record LDA keeps on this Mac. The record stores counts, entity types, document names, and timestamps. It does not store the protected values or the replacement mapping, so this report cannot reproduce them.

        Documents were processed on this device. The app's document pipeline carries no network entitlement; the only network capability in the app is the optional model download. Session records and mappings are encrypted at rest with keys held in the macOS Keychain.

        Automated detection is fallible and the workflow includes a human review step. This report documents what was recorded for this session. It is not legal advice and does not replace a lawyer's compliance judgment.

        """

        let markdown = ComplianceReport.markdown(
            record: makeFullRecord(),
            generatedAtISO8601: Self.generatedAt
        )

        XCTAssertEqual(markdown, expected)
    }

    func testOldFormatRecordRendersNotRecordedEverywhere() {
        let markdown = ComplianceReport.markdown(
            record: makeOldFormatRecord(),
            generatedAtISO8601: Self.generatedAt
        )

        XCTAssertTrue(markdown.contains("| Client label | not recorded |"))
        XCTAssertTrue(markdown.contains("| App version | not recorded |"))
        XCTAssertTrue(markdown.contains("| Detection model | not recorded |"))
        XCTAssertTrue(markdown.contains("| Substitution style | not recorded |"))
        XCTAssertTrue(markdown.contains("Not recorded."))
        XCTAssertTrue(markdown.contains("No restore has been recorded for this session."))
        // Per-type counts absent: the row falls back to the distinct type list.
        XCTAssertTrue(markdown.contains("| old.txt | 2 | EMAIL, PERSON |"))
    }

    /// Claims discipline (docs/positioning-claims.md): the report must never
    /// carry an absolute claim, whatever the record contents are.
    func testForbiddenClaimPhrasesNeverAppear() {
        let forbiddenPhrases = [
            "100%",
            "zero upload",
            "never leaves the machine",
            "guaranteed",
            "all sensitive information"
        ]
        let outputs = [
            ComplianceReport.markdown(record: makeFullRecord(), generatedAtISO8601: Self.generatedAt),
            ComplianceReport.markdown(record: makeOldFormatRecord(), generatedAtISO8601: Self.generatedAt)
        ]

        for output in outputs {
            let lowered = output.lowercased()
            for phrase in forbiddenPhrases {
                XCTAssertFalse(
                    lowered.contains(phrase.lowercased()),
                    "Report must not contain the phrase: \(phrase)"
                )
            }
        }
    }

    /// House rule: no em-dash and no en-dash anywhere, including generated
    /// deliverables.
    func testGeneratedMarkdownContainsNoBannedDashes() {
        let outputs = [
            ComplianceReport.markdown(record: makeFullRecord(), generatedAtISO8601: Self.generatedAt),
            ComplianceReport.markdown(record: makeOldFormatRecord(), generatedAtISO8601: Self.generatedAt)
        ]

        for output in outputs {
            XCTAssertFalse(output.contains("\u{2014}"), "Report must not contain an em-dash")
            XCTAssertFalse(output.contains("\u{2013}"), "Report must not contain an en-dash")
        }
    }

    /// The generator's input is the record and the timestamp scalar only, so
    /// the output can hold nothing but what the record holds. Plant one
    /// distinctive marker per record field and confirm each renders exactly
    /// once, inside its own section.
    func testMarkerFieldsRenderInsideTheirOwnSections() throws {
        let clientMarker = "CLIENTMARKER9Q4Z"
        let documentMarker = "DOCMARKER7T2X.docx"
        let record = SessionRecord(
            createdAtISO8601: "2026-08-30T10:00:00Z",
            clientLabel: clientMarker,
            documents: [
                SessionRecordDocument(name: documentMarker, entityCount: 1, entityTypes: ["EMAIL"])
            ],
            protectedValueCount: 1
        )

        let markdown = ComplianceReport.markdown(record: record, generatedAtISO8601: Self.generatedAt)

        XCTAssertEqual(occurrences(of: clientMarker, in: markdown), 1)
        XCTAssertEqual(occurrences(of: documentMarker, in: markdown), 1)

        let sessionHeader = try XCTUnwrap(markdown.range(of: "## Session"))
        let documentsHeader = try XCTUnwrap(markdown.range(of: "## Documents"))
        let verificationHeader = try XCTUnwrap(markdown.range(of: "## Verification"))
        let clientRange = try XCTUnwrap(markdown.range(of: clientMarker))
        let documentRange = try XCTUnwrap(markdown.range(of: documentMarker))

        XCTAssertTrue(clientRange.lowerBound > sessionHeader.upperBound)
        XCTAssertTrue(clientRange.upperBound < documentsHeader.lowerBound)
        XCTAssertTrue(documentRange.lowerBound > documentsHeader.upperBound)
        XCTAssertTrue(documentRange.upperBound < verificationHeader.lowerBound)
    }

    /// Record strings are data, never Markdown: a pipe or newline inside a
    /// name must not break the table it renders in.
    func testTableCellsEscapePipesAndNewlines() {
        let record = SessionRecord(
            createdAtISO8601: "2026-08-30T10:00:00Z",
            clientLabel: "acme|corp",
            documents: [
                SessionRecordDocument(
                    name: "weird|name\nand.txt",
                    entityCount: 1,
                    entityTypes: ["EMAIL"]
                )
            ],
            protectedValueCount: 1
        )

        let markdown = ComplianceReport.markdown(record: record, generatedAtISO8601: Self.generatedAt)

        XCTAssertTrue(markdown.contains("| Client label | acme\\|corp |"))
        XCTAssertTrue(markdown.contains("| weird\\|name and.txt | 1 | EMAIL |"))
        XCTAssertFalse(markdown.contains("weird|name"))
    }

    func testEmptyDocumentListRendersPlaceholderLine() {
        let record = SessionRecord(
            createdAtISO8601: "2026-08-30T10:00:00Z",
            clientLabel: nil,
            documents: [],
            protectedValueCount: 0
        )

        let markdown = ComplianceReport.markdown(record: record, generatedAtISO8601: Self.generatedAt)

        XCTAssertTrue(markdown.contains("No documents were recorded."))
    }
}
