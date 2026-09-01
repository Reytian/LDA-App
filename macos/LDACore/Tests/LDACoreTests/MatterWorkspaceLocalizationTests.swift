import Foundation
import XCTest
@testable import LDAUI

final class MatterWorkspaceLocalizationTests: XCTestCase {
    func testEmptyAndFailurePresentationSelectsStableLocalizationKeys() {
        XCTAssertEqual(
            MatterWorkspaceLocalization.loadFailureTitleKey(
                clientListFailed: true,
                historyFailed: true,
                metadataFailed: false
            ),
            "Some workspace data is locked"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.loadFailureTitleKey(
                clientListFailed: true,
                historyFailed: false,
                metadataFailed: false
            ),
            "Saved client list is locked"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.loadFailureTitleKey(
                clientListFailed: false,
                historyFailed: true,
                metadataFailed: false
            ),
            "Recent activity is locked"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.loadFailureTitleKey(
                clientListFailed: false,
                historyFailed: false,
                metadataFailed: true
            ),
            "Matter organization is locked"
        )

        XCTAssertEqual(
            MatterWorkspaceLocalization.emptySidebarTitleKey(
                isSearching: true,
                scope: .active
            ),
            "No matching matters"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.emptySidebarTitleKey(
                isSearching: false,
                scope: .archived
            ),
            "No archived matters"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.emptySidebarTitleKey(
                isSearching: false,
                scope: .active
            ),
            "No matters yet"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.emptyDetailTitleKey(scope: .active),
            "Keep each matter in context"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.emptyDetailTitleKey(scope: .archived),
            "No archived matters"
        )
    }

    func testFormattedWorkspaceAndActivityCopyUsesTheSelectedLanguage() {
        XCTAssertEqual(
            MatterWorkspaceLocalization.localWorkspaceSummary(
                count: 0,
                language: .french
            ),
            "Espaces de travail locaux"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.localWorkspaceSummary(
                count: 3,
                language: .french
            ),
            "3 espaces de travail locaux"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.localWorkspaceSummary(
                count: 1,
                language: .english
            ),
            "1 local workspace"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.localWorkspaceSummary(
                count: 1,
                language: .french
            ),
            "1 espace de travail local"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.activityLine(
                relativeActivity: nil,
                language: .english
            ),
            "Ready for first handoff"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.activityLine(
                relativeActivity: "3 minutes ago",
                language: .english
            ),
            "Updated 3 minutes ago"
        )
    }

    func testRestoreStatusLocalizesPresentationWhilePreservingDocumentNames() {
        XCTAssertEqual(
            MatterWorkspaceLocalization.documentLine(
                names: ["保密协议.docx", "Plan Éxécutif.pdf"],
                language: .french
            ),
            "保密协议.docx, Plan Éxécutif.pdf"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.documentLine(
                names: [],
                language: .english
            ),
            "No document names recorded"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.restoreLine(
                hasRestoreEvents: false,
                restoredCount: 0,
                flaggedCount: 0,
                language: .english
            ),
            "Awaiting restored result"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.restoreLine(
                hasRestoreEvents: true,
                restoredCount: 1,
                flaggedCount: 0,
                language: .english
            ),
            "1 value restored"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.restoreLine(
                hasRestoreEvents: true,
                restoredCount: 1,
                flaggedCount: 0,
                language: .french
            ),
            "1 valeur restaurée"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.restoreLine(
                hasRestoreEvents: true,
                restoredCount: 7,
                flaggedCount: 0,
                language: .english
            ),
            "7 values restored"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.restoreLine(
                hasRestoreEvents: true,
                restoredCount: 1,
                flaggedCount: 1,
                language: .english
            ),
            "1 value restored, 1 flagged for review"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.restoreLine(
                hasRestoreEvents: true,
                restoredCount: 7,
                flaggedCount: 2,
                language: .english
            ),
            "7 values restored, 2 flagged for review"
        )
    }

    func testMatterDatesUseTheSelectedInterfaceLanguageLocale() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        let formatterSource = try XCTUnwrap(
            source.components(separatedBy: "enum MatterDateFormatter").last
        )

        XCTAssertTrue(formatterSource.contains("language ?? AppLanguage.selected()"))
        XCTAssertEqual(
            formatterSource.components(separatedBy: ".locale = selectedLanguage.locale").count - 1,
            2
        )

        let referenceDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z")
        )
        XCTAssertEqual(
            MatterDateFormatter.relative(
                "2026-09-01T12:00:00Z",
                language: .english,
                relativeTo: referenceDate
            ),
            "yesterday"
        )
        XCTAssertEqual(
            MatterDateFormatter.relative(
                "2026-09-01T12:00:00Z",
                language: .french,
                relativeTo: referenceDate
            ),
            "hier"
        )

        let englishDate = MatterDateFormatter.full(
            "2026-09-01T12:00:00Z",
            language: .english
        )
        let frenchDate = MatterDateFormatter.full(
            "2026-09-01T12:00:00Z",
            language: .french
        )
        XCTAssertNotEqual(englishDate, frenchDate)
        XCTAssertTrue(frenchDate.localizedCaseInsensitiveContains("sept"))
    }

    func testConditionalLabelsResolveToCatalogKeys() {
        XCTAssertEqual(
            MatterWorkspaceLocalization.archiveActionKey(isArchived: true),
            "Restore to Active"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.archiveActionKey(isArchived: false),
            "Archive Matter"
        )
        XCTAssertEqual(MatterWorkspaceLocalization.handoffLabelKey(count: 1), "Handoff")
        XCTAssertEqual(MatterWorkspaceLocalization.handoffLabelKey(count: 2), "Handoffs")
        XCTAssertEqual(MatterWorkspaceLocalization.documentLabelKey(count: 1), "Document")
        XCTAssertEqual(MatterWorkspaceLocalization.documentLabelKey(count: 2), "Documents")
        XCTAssertEqual(
            MatterWorkspaceLocalization.identityLabelKey(count: 1),
            "Known Identity"
        )
        XCTAssertEqual(
            MatterWorkspaceLocalization.identityLabelKey(count: 2),
            "Known Identities"
        )
        XCTAssertEqual(MatterWorkspaceLocalization.restoreLabelKey(count: 1), "Restore")
        XCTAssertEqual(MatterWorkspaceLocalization.restoreLabelKey(count: 2), "Restores")
    }

    func testMatterWorkspaceKeepsUserValuesVerbatimAtTheViewBoundary() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Text(summary.label)"))
        XCTAssertTrue(source.contains(".navigationTitle(summary.label)"))
        XCTAssertFalse(source.contains("Text(summaries.isEmpty ?"))
        XCTAssertFalse(source.contains("Text(scope == .archived ?"))
        XCTAssertFalse(source.contains("Text(workspaceError ??"))
        XCTAssertFalse(source.contains("Text(errorMessage ??"))
    }

    private static let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAUI/MatterWorkspaceView.swift")
}
