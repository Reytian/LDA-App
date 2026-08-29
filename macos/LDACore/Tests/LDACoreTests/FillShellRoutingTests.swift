import XCTest
import LDACore
@testable import LDAUI

final class FillShellRoutingTests: XCTestCase {
    func testNormalStagesMapToTheirWorkflowSurface() {
        let report = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/filled.docx"),
            filledCount: 1,
            skipped: []
        )
        let cases: [(FillStage, FillShellSurface)] = [
            (.idle, .profile),
            (.library, .library),
            (.importingSources, .profile),
            (.extracting, .profile),
            (.profileReady, .profile),
            (.planning, .review),
            (.reviewing, .review),
            (.applying, .review),
            (.done(report), .review)
        ]

        for (stage, expected) in cases {
            XCTAssertEqual(
                FillShell.surface(for: stage, failureContext: nil),
                expected,
                "Unexpected surface for stage \(stage)"
            )
        }
    }

    func testFailureUsesRecordedContextInsteadOfRetainedWorkflowData() {
        let failure = FillStage.failed("Operation failed")

        XCTAssertEqual(
            FillShell.surface(for: failure, failureContext: .library),
            .library
        )
        XCTAssertEqual(
            FillShell.surface(for: failure, failureContext: .profile),
            .profile
        )
        XCTAssertEqual(
            FillShell.surface(for: failure, failureContext: .review),
            .review
        )
    }

    func testFailureWithoutRecordedContextDefaultsToLibrary() {
        XCTAssertEqual(
            FillShell.surface(
                for: .failed("Unknown failure"),
                failureContext: nil
            ),
            .library
        )
    }
}
