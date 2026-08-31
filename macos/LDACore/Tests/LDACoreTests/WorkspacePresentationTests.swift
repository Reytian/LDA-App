//
//  WorkspacePresentationTests.swift
//  LDACoreTests
//
//  The workspace flow's presentation decisions: when Save Workspace is
//  available, what opening one over live work must ask first, what a
//  passphrase pair has to satisfy, and what the user is told afterwards.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class WorkspacePresentationTests: XCTestCase {

    // MARK: - Save gating

    func testSaveIsUnavailableWithoutDocuments() {
        XCTAssertFalse(WorkspacePresentation.canSave(documentCount: 0))
        XCTAssertTrue(WorkspacePresentation.canSave(documentCount: 1))
    }

    func testTheProposedFileNameDoesNotCarryTheMatter() {
        // The archive encrypts its own entry names precisely because file names
        // carry party names. Defaulting the OUTER name to the matter would put
        // the party back on the outside of the envelope.
        let name = WorkspacePresentation.proposedFileName()
        XCTAssertTrue(name.hasSuffix(".\(WorkspaceArchive.fileExtension)"))
        XCTAssertEqual(name, "LDA Workspace.ldawork")
    }

    // MARK: - Passphrase

    func testAPassphrasePairMustBeNonEmptyLongEnoughAndMatching() {
        XCTAssertEqual(
            WorkspacePresentation.passphraseIssue(passphrase: "", confirmation: ""),
            .empty
        )
        XCTAssertEqual(
            WorkspacePresentation.passphraseIssue(passphrase: "short", confirmation: "short"),
            .tooShort(minimum: WorkspacePresentation.minimumPassphraseLength)
        )
        XCTAssertEqual(
            WorkspacePresentation.passphraseIssue(
                passphrase: "long enough",
                confirmation: "long enougi"
            ),
            .mismatch
        )
        XCTAssertNil(
            WorkspacePresentation.passphraseIssue(
                passphrase: "long enough",
                confirmation: "long enough"
            )
        )
    }

    func testTheIrrecoverabilityNoteSaysWhatTheAppDoesWithoutAbsoluteClaims() {
        let note = WorkspacePresentation.irrecoverabilityNote
        XCTAssertTrue(note.contains("does not keep a copy"))
        for absolute in ["never", "impossible", "cannot ever", "no one"] {
            XCTAssertFalse(
                note.lowercased().contains(absolute),
                "the warning makes an absolute claim: \(absolute)"
            )
        }
    }

    // MARK: - Opening over live work

    func testOpeningOverLiveWorkAsksFirst() {
        XCTAssertEqual(
            WorkspacePresentation.openConflict(hasActiveWork: true),
            .confirmReplacement
        )
        XCTAssertEqual(
            WorkspacePresentation.openConflict(hasActiveWork: false),
            .openImmediately
        )
    }

    func testTheFlowAsksBeforeReplacingAndGoesStraightThroughOtherwise() {
        let flow = WorkspaceFlowModel()
        let url = URL(fileURLWithPath: "/tmp/matter.ldawork")

        flow.requestOpen(url, hasActiveWork: true)
        XCTAssertEqual(flow.stage, .confirmReplacement(url))
        XCTAssertEqual(flow.confirmationURL, url)
        XCTAssertFalse(flow.isSheetPresented)

        flow.cancel()
        flow.requestOpen(url, hasActiveWork: false)
        XCTAssertEqual(flow.stage, .opening(url))
        XCTAssertTrue(flow.isSheetPresented)
    }

    func testCancellingClearsTypedPassphrasesAndAnyPendingOpen() {
        let flow = WorkspaceFlowModel()
        flow.stage = .saving(URL(fileURLWithPath: "/tmp/out.ldawork"))
        flow.passphrase = "typed secret"
        flow.confirmation = "typed secret"
        flow.pendingOpenAfterSave = URL(fileURLWithPath: "/tmp/other.ldawork")

        flow.cancel()

        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(flow.passphrase.isEmpty)
        XCTAssertTrue(flow.confirmation.isEmpty)
        XCTAssertNil(flow.pendingOpenAfterSave)
    }

    // MARK: - Outcome copy

    func testTheSummaryNamesTheMatterAndTheRestoredDecisions() {
        let line = WorkspacePresentation.summary(
            WorkspaceOpenSummary(
                documentCount: 2,
                matterLabel: "Nantong Textile v. Zhang",
                restoredEntityCount: 7,
                warnings: []
            )
        )
        XCTAssertEqual(
            line,
            "Opened 2 documents under Nantong Textile v. Zhang. 7 review decisions restored."
        )
    }

    func testASingleDocumentWorkspaceReadsNaturally() {
        let line = WorkspacePresentation.summary(
            WorkspaceOpenSummary(
                documentCount: 1,
                matterLabel: nil,
                restoredEntityCount: 0,
                warnings: []
            )
        )
        XCTAssertEqual(line, "Opened 1 document.")
    }

    func testWarningsSurviveIntoTheSummary() {
        let line = WorkspacePresentation.summary(
            WorkspaceOpenSummary(
                documentCount: 1,
                matterLabel: nil,
                restoredEntityCount: 1,
                warnings: ["Two values could not be found."]
            )
        )
        XCTAssertTrue(line.contains("Two values could not be found."))
    }

    func testAFailureRepeatsTheTypedError() {
        let line = WorkspacePresentation.failure(
            WorkspaceArchiveError.wrongPassphrase,
            action: "Opening the workspace"
        )
        XCTAssertTrue(line.hasPrefix("Opening the workspace failed."))
        XCTAssertTrue(line.contains("did not open this workspace"))
    }
}
