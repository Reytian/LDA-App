import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class MatterWorkspacePresentationTests: XCTestCase {
    func testMattersIsAvailableWithoutChangingTheDefaultWorkingMode() {
        XCTAssertEqual(AppMode.matters.rawValue, "Matters")
        XCTAssertEqual(AppModeStore().activeMode, .anonymize)
    }

    func testSummariesMergeStoredClientsWithEncryptedSessionHistory() throws {
        let garciaOlder = record(
            createdAt: "2026-07-16T09:00:00Z",
            client: "Garcia: Deal",
            documents: [
                SessionRecordDocument(name: "draft.docx", entityCount: 3, entityTypes: ["PERSON"])
            ],
            protectedValues: 3
        )
        let garciaNewer = record(
            createdAt: "2026-07-17T10:00:00Z",
            client: "Garcia: Deal",
            documents: [
                SessionRecordDocument(name: "exhibit.pdf", entityCount: 2, entityTypes: ["PERSON"]),
                SessionRecordDocument(name: "notes.txt", entityCount: 2, entityTypes: ["EMAIL"])
            ],
            protectedValues: 4,
            restores: [
                SessionRestoreEvent(
                    atISO8601: "2026-07-18T11:00:00Z",
                    restoredCount: 4,
                    orphanCount: 1,
                    suspectCount: 0
                ),
                SessionRestoreEvent(
                    atISO8601: "2026-07-18T12:00:00Z",
                    restoredCount: 4,
                    orphanCount: 0,
                    suspectCount: 1
                )
            ]
        )
        let acme = record(
            createdAt: "2026-07-17T14:00:00Z",
            client: "Acme Matter",
            documents: [
                SessionRecordDocument(name: "agreement.pdf", entityCount: 2, entityTypes: ["COMPANY"])
            ],
            protectedValues: 2
        )
        let oneOff = record(
            createdAt: "2026-07-18T15:00:00Z",
            client: nil,
            documents: [
                SessionRecordDocument(name: "one-off.txt", entityCount: 1, entityTypes: ["EMAIL"])
            ],
            protectedValues: 1
        )

        let summaries = MatterWorkspacePresentation.summaries(
            clientLabels: ["Garcia Deal", "Acme Matter", "Beta Matter"],
            records: [garciaOlder, garciaNewer, acme, oneOff]
        )

        XCTAssertEqual(
            summaries.map(\.label),
            ["Garcia: Deal", "Acme Matter", "Beta Matter", "Garcia Deal"]
        )
        let garcia = try XCTUnwrap(summaries.first)
        XCTAssertEqual(garcia.sessionCount, 2)
        XCTAssertEqual(garcia.documentCount, 3)
        XCTAssertEqual(garcia.protectedValueCount, 4)
        XCTAssertEqual(garcia.restoreCount, 2)
        XCTAssertEqual(garcia.flaggedCount, 2)
        XCTAssertEqual(garcia.lastActivityISO8601, "2026-07-18T12:00:00Z")

        XCTAssertNil(summaries.last?.lastActivityISO8601)
    }

    func testRecentRecordsUseTheSameMatterIdentityAndNewestFirst() {
        let older = record(
            createdAt: "2026-07-15T08:00:00Z",
            client: "Garcia: Deal",
            documents: [],
            protectedValues: 0
        )
        let newer = record(
            createdAt: "2026-07-16T08:00:00Z",
            client: "Garcia: Deal",
            documents: [],
            protectedValues: 0
        )
        let unrelated = record(
            createdAt: "2026-07-18T08:00:00Z",
            client: "Other Matter",
            documents: [],
            protectedValues: 0
        )

        let recent = MatterWorkspacePresentation.records(
            for: "Garcia: Deal",
            from: [older, unrelated, newer]
        )

        XCTAssertEqual(recent.map(\.id), [newer.id, older.id])
    }

    func testPunctuationDifferencesRemainSeparatePrivacyBoundaries() {
        let colon = record(
            createdAt: "2026-07-17T08:00:00Z",
            client: "Garcia: Deal",
            documents: [],
            protectedValues: 2
        )
        let plain = record(
            createdAt: "2026-07-18T08:00:00Z",
            client: "Garcia Deal",
            documents: [],
            protectedValues: 5
        )

        let summaries = MatterWorkspacePresentation.summaries(
            clientLabels: [],
            records: [colon, plain]
        )

        XCTAssertEqual(summaries.map(\.label), ["Garcia Deal", "Garcia: Deal"])
        XCTAssertEqual(summaries.map(\.sessionCount), [1, 1])
        XCTAssertEqual(
            MatterWorkspacePresentation.records(for: "Garcia: Deal", from: [colon, plain]).map(\.id),
            [colon.id]
        )
    }

    func testNewMatterLabelsAreCleanedBeforeStartingWork() {
        XCTAssertEqual(
            MatterWorkspacePresentation.cleanedLabel("  Acme\n   Matter  "),
            "Acme Matter"
        )
        XCTAssertNil(MatterWorkspacePresentation.cleanedLabel(" \n "))
    }

    func testWorkspaceDestinationsRouteToExistingGuidedFlows() {
        XCTAssertEqual(MatterWorkspaceDestination.anonymize.appMode, .anonymize)
        XCTAssertEqual(MatterWorkspaceDestination.restore.appMode, .deanonymize)
    }

    func testRenameMetadataCombinesOldHistoryUnderTheNewExactLabel() throws {
        let oldRecord = record(
            createdAt: "2026-07-18T08:00:00Z",
            client: "Acme Matter",
            documents: [
                SessionRecordDocument(name: "agreement.docx", entityCount: 2, entityTypes: ["COMPANY"])
            ],
            protectedValues: 2
        )
        let metadata = MatterMetadata(
            label: "Acme Transaction",
            aliases: ["Acme Matter"]
        )

        let summaries = MatterWorkspacePresentation.summaries(
            clientLabels: ["Acme Matter"],
            records: [oldRecord],
            metadata: [metadata]
        )

        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summary.label, "Acme Transaction")
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.protectedValueCount, 2)
        XCTAssertFalse(summary.isArchived)
        XCTAssertEqual(
            MatterWorkspacePresentation.records(
                for: "Acme Transaction",
                from: [oldRecord],
                metadata: [metadata]
            ).map(\.id),
            [oldRecord.id]
        )
    }

    func testArchiveMetadataSeparatesActiveAndArchivedMatters() {
        let metadata = MatterMetadata(label: "Archived Matter", isArchived: true)
        let summaries = MatterWorkspacePresentation.summaries(
            clientLabels: ["Active Matter", "Archived Matter"],
            records: [],
            metadata: [metadata]
        )

        XCTAssertEqual(
            MatterWorkspacePresentation.summaries(summaries, in: .active).map(\.label),
            ["Active Matter"]
        )
        XCTAssertEqual(
            MatterWorkspacePresentation.summaries(summaries, in: .archived).map(\.label),
            ["Archived Matter"]
        )
        XCTAssertTrue(summaries.first { $0.label == "Archived Matter" }?.isArchived == true)
    }

    private func record(
        createdAt: String,
        client: String?,
        documents: [SessionRecordDocument],
        protectedValues: Int,
        restores: [SessionRestoreEvent] = []
    ) -> SessionRecord {
        SessionRecord(
            createdAtISO8601: createdAt,
            clientLabel: client,
            documents: documents,
            protectedValueCount: protectedValues,
            restoreEvents: restores
        )
    }
}
