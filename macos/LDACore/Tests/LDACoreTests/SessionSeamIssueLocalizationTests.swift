//
//  SessionSeamIssueLocalizationTests.swift
//  LDACoreTests
//
//  The engine keeps seam failures as structured data until they reach a
//  presentation boundary. External command and MCP consumers still receive
//  the established English lines, while the app can render the same facts in
//  the selected interface language without parsing those lines.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class SessionSeamIssueLocalizationTests: XCTestCase {
    func testEnglishCompatibilityDescriptionForUncheckedDocument() {
        let issue = SessionSeamIssue.verificationUnavailable(
            documentIndex: 0,
            documentName: "contract.docx"
        )

        XCTAssertEqual(
            issue.englishDescription,
            "contract.docx: the seam check could not run on this document, so "
                + "it is NOT known whether restoring it returns the original "
                + "text. Read the restored output before relying on it."
        )
    }

    func testEnglishCompatibilityDescriptionForUnexpectedReplacement() {
        let issue = SessionSeamIssue.unexpectedReplacement(
            documentIndex: 1,
            documentName: "reply.txt",
            matchedReplacement: "Party A"
        )

        XCTAssertEqual(
            issue.englishDescription,
            "reply.txt: the redacted text spells Party A where it was never "
                + "substituted, so restore would replace it there."
        )
    }

    func testEnglishCompatibilityDescriptionForWrongEntity() {
        let issue = SessionSeamIssue.wrongEntity(
            documentIndex: 2,
            documentName: "term-sheet.txt",
            matchedReplacement: "Party A",
            shadowedReplacement: "Party B"
        )

        XCTAssertEqual(
            issue.englishDescription,
            "term-sheet.txt: the redacted text spells Party A across the site "
                + "holding Party B, so that site would restore to the wrong entity."
        )
    }

    func testAppPresentationFormatsAllThreeIssueTypesFromStructuredValues() {
        let issues: [SessionSeamIssue] = [
            .verificationUnavailable(documentIndex: 0, documentName: "one.docx"),
            .unexpectedReplacement(
                documentIndex: 1,
                documentName: "two.docx",
                matchedReplacement: "甲公司"
            ),
            .wrongEntity(
                documentIndex: 2,
                documentName: "three.docx",
                matchedReplacement: "Party A",
                shadowedReplacement: "Party B"
            )
        ]

        XCTAssertEqual(
            issues.map {
                AnonymizeWorkflowPresentation.unresolvedSeamDescription(
                    for: $0,
                    language: .english
                )
            },
            issues.map(\.englishDescription)
        )
    }

    func testAppPresentationLocalizesDefensiveDocumentLabel() {
        let issue = SessionSeamIssue.unexpectedReplacement(
            documentIndex: 3,
            documentName: nil,
            matchedReplacement: "Party A"
        )

        XCTAssertEqual(
            AnonymizeWorkflowPresentation.unresolvedSeamDescription(
                for: issue,
                language: .english
            ),
            "document 4: the redacted text spells Party A where it was never "
                + "substituted, so restore would replace it there."
        )
    }

    func testSessionResultDerivesLegacyLinesFromStructuredIssues() {
        let issue = SessionSeamIssue.unexpectedReplacement(
            documentIndex: 0,
            documentName: "contract.txt",
            matchedReplacement: "甲公司"
        )
        let result = SessionTokenizeResult(
            documents: [],
            mapping: Mapping(
                entries: [:],
                createdAtISO8601: "2026-09-01T00:00:00Z",
                sourceFile: "session",
                style: .pseudonym
            ),
            seamIssues: [issue]
        )

        XCTAssertEqual(result.seamIssues, [issue])
        XCTAssertEqual(result.unresolvedSeams, [issue.englishDescription])
    }
}
