//
//  CLITrackedChangeSummaryTests.swift
//  LDACoreTests
//
//  The anonymize summary carries the docx tracked-change count as a defaulted
//  field (older fixtures and consumers omit it), and the CLI prints a one-line
//  warning on stderr when the count is non-zero.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore

final class CLITrackedChangeSummaryTests: XCTestCase {

    private func result(trackedChangeCount: Int) -> AnonymizeResult {
        AnonymizeResult(
            redactedFileURL: URL(fileURLWithPath: "/out/a_redacted.docx"),
            mappingFileURL: URL(fileURLWithPath: "/out/a_redacted.ldamap"),
            visualPdfURL: nil,
            entityCount: 1,
            entities: [],
            trackedChangeCount: trackedChangeCount
        )
    }

    func testSummaryCarriesTheTrackedChangeCountAndRoundTrips() throws {
        let summary = AnonymizeSummaryJSON(result: result(trackedChangeCount: 3))

        XCTAssertEqual(summary.trackedChangeCount, 3)
        let encoded = try CLIJSON.encode(summary)
        XCTAssertTrue(encoded.contains("trackedChangeCount"), encoded)
        let decoded = try JSONDecoder().decode(AnonymizeSummaryJSON.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded, summary)
    }

    func testSummaryWithoutTheFieldDecodesAsZero() throws {
        let json = """
        {"redactedFileURL":"/out/a_redacted.txt","mappingFileURL":"/out/a_redacted.ldamap",\
        "visualPdfURL":null,"redactedImageURL":null,"entityCount":1,"imageRedactionCount":0,\
        "embeddedMediaCount":0,"unboxedTokenCount":0}
        """

        let decoded = try JSONDecoder().decode(AnonymizeSummaryJSON.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.trackedChangeCount, 0)
        XCTAssertEqual(decoded.entityCount, 1)
    }

    func testTrackedChangeNoticeIsSilentAtZeroAndWarnsOtherwise() throws {
        XCTAssertNil(LDACLI.trackedChangeNotice(count: 0))

        let plural = try XCTUnwrap(LDACLI.trackedChangeNotice(count: 2))
        XCTAssertTrue(plural.hasPrefix("Warning: the document carries 2 tracked changes."), plural)
        XCTAssertTrue(plural.contains("Accept all changes before redacting"), plural)
        XCTAssertTrue(plural.contains("authors are blanked"), plural)
        XCTAssertTrue(plural.hasSuffix("\n"), "one stderr line, newline terminated")
        XCTAssertFalse(plural.dropLast().contains("\n"), "one line, not a paragraph")

        let singular = try XCTUnwrap(LDACLI.trackedChangeNotice(count: 1))
        XCTAssertTrue(singular.hasPrefix("Warning: the document carries 1 tracked change."), singular)
    }
}
