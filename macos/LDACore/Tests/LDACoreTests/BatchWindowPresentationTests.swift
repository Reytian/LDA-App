//
//  BatchWindowPresentationTests.swift
//  LDACoreTests
//
//  The batch window's text after a run: one summary line without the zero
//  counts, and a list of only the documents that need attention, the same
//  ones the report names under "Failed" and "Check these".
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class BatchWindowPresentationTests: XCTestCase {
    private func item(
        _ source: String,
        _ status: BatchItem.Status,
        unboxed: Int = 0,
        media: Int = 0,
        tracked: Int = 0,
        reason: String? = nil
    ) -> BatchItem {
        BatchItem(
            source: source, status: status, replacedCount: 4, autoProtectedValueCount: 0,
            unboxedTokenCount: unboxed, embeddedMediaCount: media, trackedChangeCount: tracked, seconds: 0,
            reason: reason, sourceSize: 0, sourceModified: 0
        )
    }

    private func report(_ items: [BatchItem]) -> BatchReport {
        BatchReport(
            format: BatchReport.currentFormat,
            startedAt: "2026-10-28T00:00:00Z",
            sourceFolderName: "Clients",
            detection: "LDA V4",
            style: "token",
            mappingProtection: "keychain",
            unlocatedPolicy: "protect",
            cancelled: false,
            items: items
        )
    }

    func testSummaryLeavesOutTheCountsThatAreZero() {
        let clean = report([item("a.txt", .done), item("b.txt", .done)])
        XCTAssertEqual(BatchAnonymizeModel.summary(for: clean, language: .english), "2 written")

        let mixed = report([item("a.txt", .done), item("b.txt", .skipped), item("c.docx", .failed, reason: "corrupt")])
        XCTAssertEqual(
            BatchAnonymizeModel.summary(for: mixed, language: .english),
            "1 written · 1 finished in an earlier run · 1 not written"
        )
        XCTAssertEqual(
            BatchAnonymizeModel.summary(for: mixed, language: .simplifiedChinese),
            "已写出 1 份 · 1 份已在之前的运行中完成 · 1 份未写出"
        )
    }

    func testOnlyDocumentsThatNeedAttentionAreListed() {
        let problems = BatchAnonymizeModel.problems(in: report([
            item("clean.txt", .done),
            item("broken.docx", .failed, reason: "The document is corrupt"),
            item("scan.pdf", .done, unboxed: 1),
            item("old.docx", .skipped, media: 2, tracked: 3),
        ]), language: .english)

        XCTAssertEqual(problems.map(\.source), ["broken.docx", "scan.pdf", "old.docx"])
        XCTAssertEqual(problems.map(\.failed), [true, false, false])
        XCTAssertEqual(problems[0].lines, ["Not written: The document is corrupt"])
        XCTAssertEqual(
            problems[1].lines,
            ["Values the review PDF still shows: 1. Share the redacted text, not the review PDF."]
        )
        XCTAssertEqual(problems[2].lines, [
            "Embedded images copied without scanning, such as signatures or stamps: 2.",
            "Tracked changes: 3. Accept them before redacting for an exact round trip.",
        ])
    }

    func testACleanRunListsNothing() {
        let clean = report([item("a.txt", .done), item("b.txt", .skipped)])
        XCTAssertTrue(BatchAnonymizeModel.problems(in: clean, language: .english).isEmpty)
    }
}
