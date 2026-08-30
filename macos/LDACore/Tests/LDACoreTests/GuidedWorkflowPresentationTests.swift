import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class GuidedWorkflowPresentationTests: XCTestCase {
    func testRestoreModeUsesPlainLanguageLabel() {
        XCTAssertEqual(AppMode.deanonymize.rawValue, "Restore")
    }

    // MARK: - Cross-document re-scan advice

    func testRescanAdviceIsSilentWhenEveryDocumentIsCovered() {
        XCTAssertNil(AnonymizeWorkflowPresentation.rescanAdvice(for: []))
    }

    func testRescanAdviceNamesTheOneDocumentAndTheActionThatFixesIt() {
        let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: [
            SessionModel.RescanWarning(
                entryID: UUID(),
                documentName: "b.txt",
                missedPartyCount: 1
            )
        ])

        XCTAssertEqual(
            advice,
            "b.txt still contains 1 name protected elsewhere in this session. "
                + "Run Scan on it again, then copy."
        )
    }

    func testRescanAdviceListsEveryUncoveredDocument() {
        let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: [
            SessionModel.RescanWarning(entryID: UUID(), documentName: "b.txt", missedPartyCount: 1),
            SessionModel.RescanWarning(entryID: UUID(), documentName: "c.txt", missedPartyCount: 2)
        ])

        XCTAssertEqual(
            advice,
            "b.txt, c.txt still contain 3 names protected elsewhere in this session. "
                + "Run Scan on them again, then copy."
        )
    }

    func testSafePreviewReplacesAcceptedValuesAndLeavesRejectedValuesVisible() {
        let text = "Alice emailed bob@example.com."
        let entities = [
            ReviewEntity(
                span: span(in: text, value: "Alice", type: .person),
                accepted: true
            ),
            ReviewEntity(
                span: span(in: text, value: "bob@example.com", type: .email),
                accepted: false
            )
        ]

        XCTAssertEqual(
            ReviewModel.redactedPreviewText(text: text, entities: entities),
            "{PERSON_1} emailed bob@example.com."
        )
    }

    func testSafePreviewReusesTokensAlreadyAssignedBySessionHandoff() {
        let text = "Acme Corp retained John Smith."
        let entities = [
            ReviewEntity(
                span: span(in: text, value: "Acme Corp", type: .company),
                accepted: true,
                token: "{COMPANY_7}"
            ),
            ReviewEntity(
                span: span(in: text, value: "John Smith", type: .person),
                accepted: true
            )
        ]

        XCTAssertEqual(
            ReviewModel.redactedPreviewText(text: text, entities: entities),
            "{COMPANY_7} retained {PERSON_1}."
        )
    }

    func testTokenLookupIncludesSavedClientAliases() {
        let entry = MappingEntry(
            token: "{PERSON_4}",
            value: "John Smith",
            type: .person,
            surfaceText: "John Smith",
            aliases: ["J. Smith", "John"]
        )
        let mapping = Mapping(
            entries: [entry.token: entry],
            createdAtISO8601: "2026-07-18T00:00:00Z",
            sourceFile: "client"
        )

        XCTAssertEqual(ReviewModel.tokenBySurface(mapping: mapping)["John Smith"], "{PERSON_4}")
        XCTAssertEqual(ReviewModel.tokenBySurface(mapping: mapping)["J. Smith"], "{PERSON_4}")
        XCTAssertEqual(ReviewModel.tokenBySurface(mapping: mapping)["John"], "{PERSON_4}")
    }

    func testSafePreviewKeepsOneAssignedTokenAcrossAliasSurfaces() {
        let text = "John Smith asked John to sign."
        let entities = [
            ReviewEntity(
                span: span(in: text, value: "John Smith", type: .person),
                accepted: true,
                token: "{PERSON_4}"
            ),
            ReviewEntity(
                span: span(in: text, value: "John", type: .person, occurrence: 2),
                accepted: true,
                token: "{PERSON_4}"
            )
        ]

        XCTAssertEqual(
            ReviewModel.redactedPreviewText(text: text, entities: entities),
            "{PERSON_4} asked {PERSON_4} to sign."
        )
    }

    func testAnonymizeWorkflowAdvancesFromAddThroughShare() {
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.currentStep(
                status: .idle,
                hasDocument: false,
                hasSharedOutput: false
            ),
            .add
        )
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.currentStep(
                status: .imported,
                hasDocument: true,
                hasSharedOutput: false
            ),
            .scan
        )
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.currentStep(
                status: .ready,
                hasDocument: true,
                hasSharedOutput: false
            ),
            .review
        )
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.currentStep(
                status: .ready,
                hasDocument: true,
                hasSharedOutput: true
            ),
            .share
        )
    }

    func testShareStepOnlyAdvancesForIncludedActiveDocument() {
        let readyID = UUID()
        let skippedID = UUID()
        let included = Set([readyID])

        XCTAssertTrue(
            AnonymizeWorkflowPresentation.hasSharedActiveDocument(
                activeDocumentID: readyID,
                includedDocumentIDs: included
            )
        )
        XCTAssertFalse(
            AnonymizeWorkflowPresentation.hasSharedActiveDocument(
                activeDocumentID: skippedID,
                includedDocumentIDs: included
            )
        )
    }

    func testSafePreviewDisablesDirectTextSelection() {
        XCTAssertTrue(DocumentPreviewMode.original.allowsTextSelection)
        XCTAssertFalse(DocumentPreviewMode.safePreview.allowsTextSelection)
    }

    func testFillPrimaryActionUsesProgressiveDisclosure() {
        XCTAssertEqual(
            FillProfilePrimaryAction.resolve(
                hasProfile: false,
                hasSources: false,
                needsSave: false
            ),
            .addSources
        )
        XCTAssertEqual(
            FillProfilePrimaryAction.resolve(
                hasProfile: false,
                hasSources: true,
                needsSave: false
            ),
            .extract
        )
        XCTAssertEqual(
            FillProfilePrimaryAction.resolve(
                hasProfile: true,
                hasSources: true,
                needsSave: true
            ),
            .saveAndChooseTarget
        )
        XCTAssertEqual(
            FillProfilePrimaryAction.resolve(
                hasProfile: true,
                hasSources: false,
                needsSave: false
            ),
            .chooseTarget
        )
    }

    func testFillProfileCannotPersistDuringSourceWork() {
        XCTAssertFalse(FillProfilePrimaryAction.allowsProfilePersistence(during: .importingSources))
        XCTAssertFalse(FillProfilePrimaryAction.allowsProfilePersistence(during: .extracting))
        XCTAssertTrue(FillProfilePrimaryAction.allowsProfilePersistence(during: .profileReady))
    }

    func testDirtyProfileOffersTargetChoiceWithoutSaving() {
        XCTAssertTrue(
            FillProfilePrimaryAction.offersUnsavedTargetOption(
                hasProfile: true,
                needsSave: true
            )
        )
        XCTAssertFalse(
            FillProfilePrimaryAction.offersUnsavedTargetOption(
                hasProfile: true,
                needsSave: false
            )
        )
    }

    private func span(
        in text: String,
        value: String,
        type: EntityType,
        occurrence: Int = 1
    ) -> Span {
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var range = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            range = source.range(of: value, range: searchRange)
            guard range.location != NSNotFound else { break }
            let next = range.location + range.length
            searchRange = NSRange(location: next, length: source.length - next)
        }
        precondition(range.location != NSNotFound)
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: value,
            source: .manual,
            confidence: 1,
            priority: 110
        )
    }
}
