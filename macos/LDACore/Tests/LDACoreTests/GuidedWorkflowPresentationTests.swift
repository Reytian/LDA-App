import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class GuidedWorkflowPresentationTests: XCTestCase {
    func testRestoreModeUsesPlainLanguageLabel() {
        XCTAssertEqual(AppMode.deanonymize.rawValue, "Restore")
    }

    // MARK: - Tracked changes advice

    func testTrackedChangesAdviceIsSilentForAPlainDocument() {
        XCTAssertNil(AnonymizeWorkflowPresentation.trackedChangesAdvice(count: 0, language: .english))
    }

    func testTrackedChangesAdviceNamesTheCountAndTheAuthorBlanking() {
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.trackedChangesAdvice(count: 2, language: .english),
            "This document carries tracked changes (2). Accept all changes before redacting for an exact "
                + "round trip; a value that spans a tracked change is restored into the live text and the "
                + "change is flattened. Tracked-change and comment authors are blanked in the redacted copy "
                + "and are not restored."
        )
    }

    // MARK: - Missing model advice

    func testMissingModelAdviceIsSilentWhenTheSelectedRungHasItsModel() {
        XCTAssertNil(
            AnonymizeWorkflowPresentation.missingModelAdvice(
                isModelMissing: false, hasAnyModel: false, language: .english
            )
        )
    }

    func testMissingModelAdviceNamesWhatWillAndWillNotBeFound() {
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.missingModelAdvice(
                isModelMissing: true, hasAnyModel: false, language: .english
            ),
            "No detection model is installed, so a scan will not look for names, "
                + "companies, or addresses. It still finds emails, phones, dates, "
                + "amounts, ID numbers, and case numbers. Add a model to find names."
        )
    }

    func testMissingModelAdviceDistinguishesNoModelFromTheWrongOneInstalled() {
        // Reachable on any Mac with 24 GB or more: a fresh install sits on
        // Quick, the user downloads or imports Balanced from Manage Models and
        // does not switch level. The selected rung still cannot run, so the
        // advisory must still fire, but "No detection model is installed" would
        // then be a false sentence in a redaction tool.
        let none = AnonymizeWorkflowPresentation.missingModelAdvice(
            isModelMissing: true, hasAnyModel: false, language: .english
        )
        let wrongOne = AnonymizeWorkflowPresentation.missingModelAdvice(
            isModelMissing: true, hasAnyModel: true, language: .english
        )
        XCTAssertNotNil(none)
        XCTAssertNotNil(wrongOne)
        XCTAssertNotEqual(none, wrongOne)
        XCTAssertTrue(none!.contains("No detection model is installed"))
        XCTAssertFalse(
            wrongOne!.contains("No detection model is installed"),
            "a user who HAS a model must not be told there is none"
        )
        // Both must still say what a scan will not look for. That is the whole
        // point of the row.
        for advice in [none!, wrongOne!] {
            XCTAssertTrue(advice.contains("names, companies, or addresses"))
        }
    }

    func testMissingModelAdviceIsSilentForTheSelectedRungRegardlessOfOtherModels() {
        for hasAnyModel in [true, false] {
            XCTAssertNil(
                AnonymizeWorkflowPresentation.missingModelAdvice(
                    isModelMissing: false, hasAnyModel: hasAnyModel, language: .english
                ),
                "a rung with its model needs no advisory"
            )
        }
    }

    func testMissingModelAdviceIsTranslatedRatherThanEnglishEverywhere() {
        for language in [AppLanguage.french, .simplifiedChinese, .traditionalChinese] {
            let advice = AnonymizeWorkflowPresentation.missingModelAdvice(
                isModelMissing: true, hasAnyModel: false, language: language
            )
            XCTAssertNotNil(advice)
            XCTAssertNotEqual(
                advice,
                AnonymizeWorkflowPresentation.missingModelAdvice(
                    isModelMissing: true, hasAnyModel: false, language: .english
                ),
                "\(language) must carry a real translation, not the English string"
            )
        }
    }

    func testMissingModelAdviceMakesNoTotalisingClaimAboutWhatIsFound() {
        // The advisory is the one place a lawyer learns the scan is reduced. It
        // must not reassure them that "everything else" is caught, which is
        // both false and close to a claim UIClaimsDisciplineTests bans.
        let advice = AnonymizeWorkflowPresentation.missingModelAdvice(
            isModelMissing: true, hasAnyModel: false, language: .english
        )!.lowercased()
        for claim in ["everything", "all sensitive", "guaranteed", "100%"] {
            XCTAssertFalse(advice.contains(claim), "advisory must not claim \(claim)")
        }
    }

    // MARK: - Export for AI copy

    func testExportCompletionDetailNamesTheFileAndTheSkippedDocuments() {
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.exportCompletionDetail(
                documentCount: 1,
                skippedCount: 0,
                fileName: "Redacted for AI.md",
                language: .english
            ),
            "1 redacted document is in Redacted for AI.md. "
                + "Upload it to your AI tool, then bring the answer back in Restore."
        )
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.exportCompletionDetail(
                documentCount: 2,
                skippedCount: 1,
                fileName: "Redacted for AI.md",
                language: .english
            ),
            "2 redacted documents are in Redacted for AI.md. "
                + "Upload it to your AI tool, then bring the answer back in Restore. "
                + "1 unscanned document was not included."
        )
    }

    func testExportForAIHelpCountsOnlyWhenSeveralDocumentsCouldBeIncluded() {
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.exportForAIHelp(ready: 1, candidates: 1, language: .english),
            "Save the redacted text as one Markdown file to upload to any AI tool."
        )
        XCTAssertEqual(
            AnonymizeWorkflowPresentation.exportForAIHelp(ready: 1, candidates: 3, language: .english),
            "Save the redacted text from 1 of 3 documents (only the ones already scanned are included) "
                + "as one Markdown file to upload to any AI tool."
        )
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
                + "Run Scan on it again, then export again."
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
                + "Run Scan on them again, then export again."
        )
    }

    func testRescanAdviceSendsSuppressedTermsToTheActionThatCanActuallyFixThem() {
        // Learned suppression is applied after the rescan sweep, so Scan
        // pulls this party in and drops it again. Prescribing Scan here is a
        // banner the user can never clear.
        let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: [
            SessionModel.RescanWarning(
                entryID: UUID(),
                documentName: "b.txt",
                missedPartyCount: 1,
                suppressedPartyCount: 1
            )
        ])

        XCTAssertEqual(
            advice,
            "b.txt still contains 1 name you chose not to redact before. "
                + "Scan will skip it again, so use Protect a missed item "
                + "if it should be protected here."
        )
    }

    func testRescanAdviceSeparatesTheRescannableGapFromTheSuppressedOne() {
        // One document, both kinds of gap: each sentence must count only its
        // own, so neither action is prescribed for a party it cannot fix.
        let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: [
            SessionModel.RescanWarning(
                entryID: UUID(),
                documentName: "b.txt",
                missedPartyCount: 3,
                suppressedPartyCount: 1
            )
        ])

        XCTAssertEqual(
            advice,
            "b.txt still contains 2 names protected elsewhere in this session. "
                + "Run Scan on it again, then export again. "
                + "b.txt still contains 1 name you chose not to redact before. "
                + "Scan will skip it again, so use Protect a missed item "
                + "if it should be protected here."
        )
    }

    // MARK: - Unresolved seam advice
    //
    // The plumbing that gets these lines to the banner is covered in
    // SessionSeamWarningTests; this is the sentence itself.

    func testSeamAdviceIsSilentWhenTheSessionIsClean() {
        XCTAssertNil(AnonymizeWorkflowPresentation.unresolvedSeamAdvice(for: []))
    }

    func testSeamAdviceOpensByTellingTheUserNotToUploadTheFile() {
        // The user cannot find this one by reading the copied text, so the
        // sentence has to lead with the instruction, not the explanation.
        let advice = AnonymizeWorkflowPresentation.unresolvedSeamAdvice(for: [
            "a.txt: the redacted text spells X across the site holding Y, "
                + "so that site would restore to the wrong entity."
        ])

        XCTAssertEqual(
            advice,
            "Do not upload this file. Restoring the AI's reply would put the "
                + "wrong party's name at 1 redacted site. Clear any replacement text you "
                + "typed by hand for these names (Use Automatic), or change Output style "
                + "in Settings, then export again."
        )
    }

    func testSeamAdviceCountsEverySite() {
        let advice = AnonymizeWorkflowPresentation.unresolvedSeamAdvice(for: [
            "a.txt: first.",
            "b.txt: second.",
            "b.txt: third."
        ])

        XCTAssertEqual(
            advice,
            "Do not upload this file. Restoring the AI's reply would put the "
                + "wrong party's name at 3 redacted sites. Clear any replacement text you "
                + "typed by hand for these names (Use Automatic), or change Output style "
                + "in Settings, then export again."
        )
    }

    func testSeamAdviceNamesBothLeversBecauseTheLinesNeverSayWhichOneApplies() throws {
        // The pass gives up for two reasons, hand typed replacement text and
        // an identity carried in from another output style, and the line it
        // hands back does not distinguish them. Prescribing one control would
        // send half of these users somewhere that cannot help.
        let advice = try XCTUnwrap(
            AnonymizeWorkflowPresentation.unresolvedSeamAdvice(for: ["a.txt: only seam."])
        )

        XCTAssertTrue(advice.contains("Use Automatic"), advice)
        XCTAssertTrue(advice.contains("Output style"), advice)
    }

    func testRescanAdviceGroupsDocumentsByTheActionThatFixesThem() {
        // b.txt is fixable by re-scanning, c.txt is not. Listing them in one
        // sentence would send the user to the wrong button for one of them.
        let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: [
            SessionModel.RescanWarning(entryID: UUID(), documentName: "b.txt", missedPartyCount: 1),
            SessionModel.RescanWarning(
                entryID: UUID(),
                documentName: "c.txt",
                missedPartyCount: 2,
                suppressedPartyCount: 2
            )
        ])

        XCTAssertEqual(
            advice,
            "b.txt still contains 1 name protected elsewhere in this session. "
                + "Run Scan on it again, then export again. "
                + "c.txt still contains 2 names you chose not to redact before. "
                + "Scan will skip them again, so use Protect a missed item "
                + "if they should be protected here."
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

    func testSafePreviewShowsARefusalInsteadOfUnverifiedPseudonymOutput() {
        let text = "北京鼎盛科技有限公司与甲公司签署。"
        let entities = [
            ReviewEntity(
                span: span(in: text, value: "北京鼎盛科技有限公司", type: .company),
                accepted: true,
                token: "甲公司"
            )
        ]

        XCTAssertEqual(
            ReviewModel.redactedPreviewText(
                text: text,
                entities: entities,
                style: .pseudonym,
                language: .english
            ),
            "Safe Preview unavailable: pseudonym restoration could not be verified."
        )

        XCTAssertEqual(
            ReviewModel.redactedPreviewText(
                text: text,
                entities: entities,
                style: .pseudonym,
                language: .simplifiedChinese
            ),
            "无法显示脱敏预览：无法验证化名能否正确恢复。"
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
