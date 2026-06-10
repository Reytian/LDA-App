//
//  ProfileJSONParserTests.swift
//  LDACoreTests
//
//  Defensive parsing of the profile extraction and blank match model output.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ProfileJSONParserTests: XCTestCase {

    // MARK: - parseProfileRows: clean input

    func testParsesCleanProfileArray() {
        let output = """
        [{"key": "companyName", "value": "Acme Holdings Limited", "snippet": "the name of the company is Acme Holdings Limited", "confidence": 0.95}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "companyName")
        XCTAssertEqual(rows[0].value, "Acme Holdings Limited")
        XCTAssertEqual(rows[0].confidence, 0.95, accuracy: 0.0001)
    }

    func testStripsCodeFencesAndProse() {
        let output = """
        Sure, here is the JSON:
        ```json
        [{"key": "companyNumber", "value": "1234567", "snippet": "No. 1234567", "confidence": 0.9}]
        ```
        """
        XCTAssertEqual(ProfileJSONParser.parseProfileRows(output).count, 1)
    }

    // MARK: - Row filtering

    func testRowsMissingRequiredFieldsDropped() {
        // Row 1: missing value and snippet (only key). Row 2: missing key. Row 3: valid.
        let output = """
        [{"key": "companyName"}, {"value": "x", "snippet": "x", "confidence": 1}, {"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong", "confidence": 0.8}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.map(\.key), ["jurisdiction"])
    }

    func testMissingSnippetDropsRow() {
        // snippet is required; a row without it must be dropped.
        let output = """
        [{"key": "signingDate", "value": "1 March 2024", "confidence": 0.9},
         {"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong", "confidence": 0.8}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "jurisdiction")
    }

    func testEmptySnippetIsKept() {
        // An explicitly empty snippet string is allowed (no grounding, but not dropped).
        let output = """
        [{"key": "signingDate", "value": "1 March 2024", "snippet": "", "confidence": 0.7}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].snippet, "")
    }

    func testEmptyKeyDropsRow() {
        let output = """
        [{"key": "", "value": "foo", "snippet": "foo here", "confidence": 0.8}]
        """
        XCTAssertEqual(ProfileJSONParser.parseProfileRows(output).count, 0)
    }

    func testEmptyValueDropsRow() {
        let output = """
        [{"key": "companyName", "value": "", "snippet": "no name found", "confidence": 0.8}]
        """
        XCTAssertEqual(ProfileJSONParser.parseProfileRows(output).count, 0)
    }

    // MARK: - Confidence handling

    func testConfidenceMissingDefaultsToHalf() {
        let output = """
        [{"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong"}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].confidence, 0.5, accuracy: 0.0001)
    }

    func testConfidenceBelowZeroClampedToZero() {
        let output = """
        [{"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong", "confidence": -0.1}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].confidence, 0.0, accuracy: 0.0001)
    }

    func testConfidenceAboveOneClampedToOne() {
        let output = """
        [{"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong", "confidence": 1.5}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].confidence, 1.0, accuracy: 0.0001)
    }

    // MARK: - Truncation signal (Detailed variant)

    func testUnparseableReturnsNil() {
        XCTAssertNil(ProfileJSONParser.parseProfileRowsDetailed("no json here at all"))
        XCTAssertNil(ProfileJSONParser.parseProfileRowsDetailed("[{\"key\": \"companyName\", truncated"))
    }

    func testEmptyArrayReturnsEmptyNotNil() {
        // A well-formed empty array is recoverable; Detailed must return [] not nil.
        let result = ProfileJSONParser.parseProfileRowsDetailed("[]")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 0)
    }

    func testArrayWithAllBadRowsReturnsEmptyNotNil() {
        // A decodable array whose rows all fail validation returns [], not nil.
        let output = """
        [{"key": "companyName"}, {"value": "x", "snippet": "x", "confidence": 1}]
        """
        let result = ProfileJSONParser.parseProfileRowsDetailed(output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 0)
    }

    func testProseWrappedJSONDecodes() {
        let output = """
        Based on the document, here are the extracted fields:
        [{"key": "companyName", "value": "Acme Corp", "snippet": "Acme Corp", "confidence": 0.9}]
        Hope that helps.
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "companyName")
    }

    func testStrayBalancedBraceInProseStillRecoversArray() {
        // Prose containing a small balanced {} before the real array must not
        // confuse the bracket scanner; the larger array region must win.
        let output = """
        Notes {for reference} and items [item1, item2] are not JSON.
        [{"key": "jurisdiction", "value": "Hong Kong", "snippet": "in Hong Kong", "confidence": 0.8}]
        """
        let rows = ProfileJSONParser.parseProfileRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "jurisdiction")
    }

    // MARK: - parseBlankMatchRows

    func testParsesBlankMatchRows() {
        let output = """
        [{"blank": 1, "field": 2, "value": null}, {"blank": 2, "field": null, "value": null}, {"blank": 3, "field": 1, "value": "10th"}]
        """
        let rows = ProfileJSONParser.parseBlankMatchRows(output)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].blank, 1)
        XCTAssertEqual(rows[0].field, 2)
        XCTAssertNil(rows[0].value)
        XCTAssertNil(rows[1].field)
        XCTAssertEqual(rows[2].value, "10th")
    }

    func testBlankMatchRowMissingBlankKeyDropped() {
        // A row without the required "blank" integer must be dropped.
        let output = """
        [{"field": 1, "value": "foo"}, {"blank": 2, "field": 1, "value": "bar"}]
        """
        let rows = ProfileJSONParser.parseBlankMatchRows(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].blank, 2)
    }

    func testBlankMatchDetailedReturnsNilOnGarbage() {
        XCTAssertNil(ProfileJSONParser.parseBlankMatchRowsDetailed("this is not json"))
    }
}
