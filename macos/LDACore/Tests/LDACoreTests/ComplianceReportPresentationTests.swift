//
//  ComplianceReportPresentationTests.swift
//  LDACoreTests
//
//  The report export sheet's decisions, tested without a window: which shape
//  the sheet opens on, when the confirming button is allowed, and that the
//  passphrase rule is the workspace rule rather than a second one that could
//  drift away from it.
//
//  The load-bearing assertion is testTheSheetOpensOnTheEncryptedShape. The
//  readable pair must never be what a user gets by pressing Return without
//  reading, because the readable pair carries the party names.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ComplianceReportPresentationTests: XCTestCase {

    private static let goodPassphrase = "counsel report passphrase"

    // MARK: - The default shape

    func testTheSheetOpensOnTheEncryptedShape() {
        XCTAssertEqual(ComplianceReportPresentation.defaultShape, .encrypted)
        XCTAssertEqual(ComplianceReportFlowModel().shape, .encrypted)
    }

    func testCancellingResetsTheSheetBackToTheEncryptedShape() {
        let flow = ComplianceReportFlowModel()
        flow.shape = .readable
        flow.passphrase = Self.goodPassphrase
        flow.confirmation = Self.goodPassphrase
        flow.cancel()
        XCTAssertEqual(flow.shape, .encrypted)
        XCTAssertTrue(flow.passphrase.isEmpty)
        XCTAssertTrue(flow.confirmation.isEmpty)
    }

    // MARK: - Confirm gating

    func testConfirmIsBlockedUntilThePassphrasePairIsValid() {
        XCTAssertFalse(
            ComplianceReportPresentation.canConfirmExport(
                shape: .encrypted,
                passphrase: "",
                confirmation: ""
            )
        )
        XCTAssertFalse(
            ComplianceReportPresentation.canConfirmExport(
                shape: .encrypted,
                passphrase: "short",
                confirmation: "short"
            )
        )
        XCTAssertFalse(
            ComplianceReportPresentation.canConfirmExport(
                shape: .encrypted,
                passphrase: Self.goodPassphrase,
                confirmation: "something else"
            )
        )
        XCTAssertTrue(
            ComplianceReportPresentation.canConfirmExport(
                shape: .encrypted,
                passphrase: Self.goodPassphrase,
                confirmation: Self.goodPassphrase
            )
        )
    }

    func testTheReadableShapeNeedsNoPassphrase() {
        XCTAssertTrue(
            ComplianceReportPresentation.canConfirmExport(
                shape: .readable,
                passphrase: "",
                confirmation: ""
            )
        )
    }

    // MARK: - One passphrase rule, not two

    func testThePassphraseRuleIsTheWorkspaceRule() {
        XCTAssertEqual(
            ComplianceReportPresentation.minimumPassphraseLength,
            WorkspacePresentation.minimumPassphraseLength
        )
        XCTAssertEqual(
            ComplianceReportPresentation.passphraseIssue(passphrase: "abc", confirmation: "abc"),
            .tooShort(minimum: WorkspacePresentation.minimumPassphraseLength)
        )
        XCTAssertEqual(
            ComplianceReportPresentation.passphraseIssue(
                passphrase: Self.goodPassphrase,
                confirmation: "typo"
            ),
            .mismatch
        )
        XCTAssertNil(
            ComplianceReportPresentation.passphraseIssue(
                passphrase: Self.goodPassphrase,
                confirmation: Self.goodPassphrase
            )
        )
    }

    // MARK: - Copy

    func testTheReadableWarningSaysWhatWillBeReadable() {
        let warning = ComplianceReportPresentation.readableWarning.lowercased()
        XCTAssertTrue(warning.contains("party names"))
        XCTAssertTrue(warning.contains("document"))
    }

    func testTheProtectionShapeMapsOntoTheModelApi() {
        XCTAssertEqual(
            ComplianceReportPresentation.protection(
                for: .encrypted,
                passphrase: Self.goodPassphrase
            ),
            .passphrase(Self.goodPassphrase)
        )
        XCTAssertEqual(
            ComplianceReportPresentation.protection(for: .readable, passphrase: "ignored"),
            .readable
        )
    }

    func testTheOutcomeSentenceNamesWhatWasWritten() {
        let sealed = ComplianceReportExportResult.encrypted(
            URL(fileURLWithPath: "/tmp/report.ldareport")
        )
        XCTAssertTrue(
            ComplianceReportPresentation.summary(sealed).contains("report.ldareport")
        )
        let readable = ComplianceReportExportResult.readable(
            markdown: URL(fileURLWithPath: "/tmp/report.md"),
            pdf: URL(fileURLWithPath: "/tmp/report.pdf")
        )
        let sentence = ComplianceReportPresentation.summary(readable)
        XCTAssertTrue(sentence.contains("report.md"))
        XCTAssertTrue(sentence.contains("report.pdf"))
    }

    func testReportArchiveOpenFailuresArePresentedAtTheLocalizedUIBoundary() {
        XCTAssertEqual(
            ComplianceReportPresentation.archiveErrorDescription(
                ComplianceReportArchiveError.wrongPassphrase,
                language: .english
            ),
            "That passphrase did not open this report file."
        )
        XCTAssertEqual(
            ComplianceReportPresentation.archiveErrorDescription(
                ComplianceReportArchiveError.createdByNewerVersion(
                    found: 8,
                    supported: 1
                ),
                language: .english
            ),
            "This report file was created by a newer version of LDA "
                + "(format 8; this app reads format 1). Update LDA to open it."
        )
        XCTAssertEqual(
            ComplianceReportPresentation.archiveErrorDescription(
                ComplianceReportArchiveError.damagedFile("raw 100% detail"),
                language: .english
            ),
            "This report file could not be read. raw 100% detail"
        )
    }
}
