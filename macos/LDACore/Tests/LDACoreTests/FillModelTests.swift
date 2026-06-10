//
//  FillModelTests.swift
//  LDACoreTests
//
//  Tests for the LDAUI FillModel view-model. They exercise synchronous intents
//  (accept, reject, repoint, field editing, conflict resolution, navigation),
//  async intent paths via injected fakes (extractProfile, planFill, applyFill),
//  and the applyFill gating assertion (all blanks passed through to the facade).
//
//  FillModel is @MainActor isolated; the suite is annotated @MainActor to match.
//  Fake service runners are wired via FillModel's static test-seam vars and
//  nilled out in tearDown, mirroring ReviewModelTests.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelTests: XCTestCase {

    // MARK: - Setup / teardown

    override func tearDownWithError() throws {
        // Clear all static test seams after every test so they never bleed.
        FillModel.extractProfileForTesting = nil
        FillModel.planFillForTesting = nil
        FillModel.applyFillForTesting = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A minimal CompanyProfile with two distinct fields.
    private func makeProfile(
        companyName: String = "Acme Corp",
        jurisdiction: String = "BVI"
    ) -> CompanyProfile {
        let f1 = ProfileField(
            id: UUID(),
            key: .companyName,
            value: companyName,
            sourceDocument: "test.txt",
            sourceSnippet: companyName,
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let f2 = ProfileField(
            id: UUID(),
            key: .jurisdiction,
            value: jurisdiction,
            sourceDocument: "test.txt",
            sourceSnippet: jurisdiction,
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        return CompanyProfile(
            label: "Test Co",
            fields: [f1, f2],
            sourceDocuments: ["test.txt"],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false
        )
    }

    /// A profile with a conflict: two .companyName fields with different values.
    private func makeConflictedProfile() -> CompanyProfile {
        let f1 = ProfileField(
            id: UUID(),
            key: .companyName,
            value: "Acme Corp",
            sourceDocument: "test.txt",
            sourceSnippet: "Acme Corp",
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let f2 = ProfileField(
            id: UUID(),
            key: .companyName,
            value: "ACME CORPORATION",
            sourceDocument: "other.txt",
            sourceSnippet: "ACME CORPORATION",
            snippetVerified: true,
            confidence: 0.9,
            userEdited: false
        )
        return CompanyProfile(
            label: "Test Co",
            fields: [f1, f2],
            sourceDocuments: ["test.txt", "other.txt"],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false
        )
    }

    /// A single Blank in .proposed status with a non-nil proposedValue.
    private func makeProposedBlank(fieldID: UUID, value: String) -> Blank {
        Blank(
            location: .acroFormField(name: "Company Name"),
            label: "Company Name",
            context: "Please fill in [Company Name]",
            proposedFieldID: fieldID,
            proposedValue: value,
            status: .proposed
        )
    }

    /// A Blank in .proposed status with proposedValue == nil (ambiguous).
    private func makeAmbiguousBlank() -> Blank {
        Blank(
            location: .acroFormField(name: "Director"),
            label: "Director",
            context: "Director: [Director]",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .proposed
        )
    }

    /// A Blank in .unmatched status.
    private func makeUnmatchedBlank() -> Blank {
        Blank(
            location: .acroFormField(name: "CustomField"),
            label: "CustomField",
            context: "[CustomField]",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .unmatched
        )
    }

    /// A Blank in .rejected status.
    private func makeRejectedBlank() -> Blank {
        Blank(
            location: .acroFormField(name: "Notes"),
            label: "Notes",
            context: "[Notes]",
            proposedFieldID: nil,
            proposedValue: nil,
            status: .rejected
        )
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let model = FillModel(modelPath: nil)
        XCTAssertEqual(model.stage, .idle)
        XCTAssertNil(model.profile)
        XCTAssertFalse(model.profileDirty)
        XCTAssertTrue(model.blanks.isEmpty)
        XCTAssertNil(model.selectedBlankID)
        XCTAssertNil(model.targetURL)
        XCTAssertTrue(model.manualWidgetNames.isEmpty)
        XCTAssertEqual(model.progress, 0)
        XCTAssertTrue(model.sourceWarnings.isEmpty)
        XCTAssertNil(model.pickerRequestID)
    }

    // MARK: - loadProfile

    func testLoadProfileSetsStageProfileReadyAndClearsDirty() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()

        model.loadProfile(profile)

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertEqual(model.profile, profile)
        XCTAssertFalse(model.profileDirty)
    }

    // MARK: - setProfile

    func testSetProfileSetsProfileAndMakesDirty() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()

        model.setProfile(profile)

        XCTAssertEqual(model.profile, profile)
        XCTAssertTrue(model.profileDirty)
    }

    // MARK: - updateField

    func testUpdateFieldMarksUserEditedAndDirty() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        let fieldID = profile.fields[0].id
        model.loadProfile(profile)
        XCTAssertFalse(model.profileDirty)

        model.updateField(id: fieldID, value: "New Name")

        XCTAssertTrue(model.profileDirty)
        let updated = model.profile?.fields.first { $0.id == fieldID }
        XCTAssertEqual(updated?.value, "New Name")
        XCTAssertTrue(updated?.userEdited == true)
    }

    func testUpdateFieldUnknownIDIsNoOp() {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())
        model.updateField(id: UUID(), value: "Ignored")
        XCTAssertFalse(model.profileDirty)
    }

    // MARK: - removeField

    func testRemoveFieldDeletesFromProfileAndMarksDirty() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        let fieldID = profile.fields[0].id
        model.loadProfile(profile)

        model.removeField(id: fieldID)

        XCTAssertFalse(model.profile?.fields.contains { $0.id == fieldID } ?? true)
        XCTAssertTrue(model.profileDirty)
    }

    // MARK: - resolveConflict

    func testResolveConflictKeepsWinnerAndConflictedKeyClears() {
        let model = FillModel(modelPath: nil)
        let conflicted = makeConflictedProfile()
        let keepField = conflicted.fields[0]
        let dropField = conflicted.fields[1]
        model.loadProfile(conflicted)

        // Confirm there is a conflict before resolving.
        XCTAssertFalse(model.profile!.conflictedKeys.isEmpty)

        model.resolveConflict(key: .companyName, keepFieldID: keepField.id)

        // The losers are removed; the winner remains.
        let remaining = model.profile!.fields
        XCTAssertTrue(remaining.contains { $0.id == keepField.id })
        XCTAssertFalse(remaining.contains { $0.id == dropField.id })

        // conflictedKeys is now empty because only one value remains.
        XCTAssertTrue(model.profile!.conflictedKeys.isEmpty)
        XCTAssertTrue(model.profileDirty)
    }

    // MARK: - acceptBlank: proposed-with-value moves to confirmed

    func testAcceptBlankProposedWithValueMovesToConfirmed() {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())
        let fieldID = model.profile!.fields[0].id
        let blank = makeProposedBlank(fieldID: fieldID, value: "Acme Corp")
        model.blanks = [blank]

        model.acceptBlank(id: blank.id)

        XCTAssertEqual(model.blanks[0].status, .confirmed)
        XCTAssertNil(model.pickerRequestID)
    }

    // MARK: - acceptBlank: nil proposedValue sets pickerRequestID, does NOT confirm

    func testAcceptBlankNilProposalSetPickerRequestIDNoConfirm() {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())
        let blank = makeAmbiguousBlank()
        model.blanks = [blank]

        model.acceptBlank(id: blank.id)

        XCTAssertEqual(model.blanks[0].status, .proposed, "ambiguous blank must not be confirmed")
        XCTAssertEqual(model.pickerRequestID, blank.id, "picker request must be set to the blank id")
    }

    // MARK: - rejectBlank: any status moves to rejected

    func testRejectBlankFromProposedToRejected() {
        let model = FillModel(modelPath: nil)
        let fieldID = UUID()
        let blank = makeProposedBlank(fieldID: fieldID, value: "Val")
        model.blanks = [blank]

        model.rejectBlank(id: blank.id)

        XCTAssertEqual(model.blanks[0].status, .rejected)
    }

    func testRejectBlankFromUnmatchedToRejected() {
        let model = FillModel(modelPath: nil)
        let blank = makeUnmatchedBlank()
        model.blanks = [blank]

        model.rejectBlank(id: blank.id)

        XCTAssertEqual(model.blanks[0].status, .rejected)
    }

    func testRejectBlankAlreadyRejectedIsIdempotent() {
        let model = FillModel(modelPath: nil)
        let blank = makeRejectedBlank()
        model.blanks = [blank]

        model.rejectBlank(id: blank.id)

        XCTAssertEqual(model.blanks[0].status, .rejected)
    }

    // MARK: - repointBlank

    func testRepointBlankSetsFieldIDValueAndProposedStatus() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        let targetField = profile.fields[1]
        model.loadProfile(profile)

        let blank = makeUnmatchedBlank()
        model.blanks = [blank]

        model.repointBlank(id: blank.id, fieldID: targetField.id)

        let updated = model.blanks[0]
        XCTAssertEqual(updated.proposedFieldID, targetField.id)
        XCTAssertEqual(updated.proposedValue, targetField.value)
        XCTAssertEqual(updated.status, .proposed)
    }

    // MARK: - acceptAllProposed

    func testAcceptAllProposedConfirmsOnlyValuedProposedBlanks() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        let fieldID = profile.fields[0].id

        let proposed = makeProposedBlank(fieldID: fieldID, value: "Acme Corp")
        let ambiguous = makeAmbiguousBlank()
        let unmatched = makeUnmatchedBlank()
        let rejected = makeRejectedBlank()
        model.blanks = [proposed, ambiguous, unmatched, rejected]

        model.acceptAllProposed()

        // Only the proposed-with-value blank moves to confirmed.
        XCTAssertEqual(model.blanks[0].status, .confirmed, "proposed-with-value must be confirmed")
        XCTAssertEqual(model.blanks[1].status, .proposed, "nil-proposal must stay proposed")
        XCTAssertEqual(model.blanks[2].status, .unmatched, "unmatched must stay unmatched")
        XCTAssertEqual(model.blanks[3].status, .rejected, "rejected must stay rejected")
    }

    // MARK: - Selection navigation

    func testSelectNextBlankWrapsAround() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        let fieldID = profile.fields[0].id

        let b0 = makeProposedBlank(fieldID: fieldID, value: "A")
        let b1 = makeProposedBlank(fieldID: fieldID, value: "B")
        let b2 = makeProposedBlank(fieldID: fieldID, value: "C")
        model.blanks = [b0, b1, b2]

        // No selection: next selects the first.
        XCTAssertNil(model.selectedBlankID)
        model.selectNextBlank()
        XCTAssertEqual(model.selectedBlankID, b0.id)

        // Advance to last.
        model.selectNextBlank()
        model.selectNextBlank()
        XCTAssertEqual(model.selectedBlankID, b2.id)

        // Wrap from last to first.
        model.selectNextBlank()
        XCTAssertEqual(model.selectedBlankID, b0.id, "next must wrap from last to first")
    }

    func testSelectPreviousBlankWrapsAround() {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        let fieldID = profile.fields[0].id

        let b0 = makeProposedBlank(fieldID: fieldID, value: "A")
        let b1 = makeProposedBlank(fieldID: fieldID, value: "B")
        let b2 = makeProposedBlank(fieldID: fieldID, value: "C")
        model.blanks = [b0, b1, b2]

        // No selection: previous selects the last.
        XCTAssertNil(model.selectedBlankID)
        model.selectPreviousBlank()
        XCTAssertEqual(model.selectedBlankID, b2.id, "previous with no selection must land on last")

        // Wrap from first to last.
        model.selectedBlankID = b0.id
        model.selectPreviousBlank()
        XCTAssertEqual(model.selectedBlankID, b2.id, "previous must wrap from first to last")
    }

    // MARK: - extractProfile async

    func testExtractProfileSuccessPublishesProfileAndStageReady() async throws {
        let model = FillModel(modelPath: "/fake/model.gguf")
        let profile = makeProfile()
        let fakeResult = ExtractProfileResult(
            profile: profile,
            failedSources: [("bad.txt", "unreadable")]
        )

        FillModel.extractProfileForTesting = { _, _, _ in fakeResult }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Test Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertEqual(model.profile, profile)
        XCTAssertFalse(model.profileDirty)
        // One failed source must surface as a warning.
        XCTAssertEqual(model.sourceWarnings.count, 1)
        XCTAssertTrue(model.sourceWarnings[0].contains("bad.txt"))
    }

    func testExtractProfileFailureSetsFailedStageWithMessage() async throws {
        let model = FillModel(modelPath: "/fake/model.gguf")

        struct FakeError: Error {
            let msg: String
        }
        FillModel.extractProfileForTesting = { _, _, _ in
            throw FakeError(msg: "engine blew up")
        }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Test Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        guard case .failed(let msg) = model.stage else {
            XCTFail("stage must be .failed; got \(model.stage)")
            return
        }
        XCTAssertFalse(msg.isEmpty, "failure message must not be empty")
    }

    // MARK: - planFill async

    func testPlanFillSuccessPublishesBlanksAndStageReviewing() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        let fieldID = profile.fields[0].id

        let blank0 = makeProposedBlank(fieldID: fieldID, value: "Acme Corp")
        let blank1 = makeUnmatchedBlank()
        let fakePlan = FillPlan(
            targetFormat: .pdf,
            blanks: [blank0, blank1],
            manualWidgetNames: ["Signature"]
        )

        FillModel.planFillForTesting = { _ in fakePlan }

        let target = URL(fileURLWithPath: "/tmp/form.pdf")
        await model.planFill(target: target)

        XCTAssertEqual(model.stage, .reviewing)
        XCTAssertEqual(model.blanks.count, 2)
        XCTAssertEqual(model.manualWidgetNames, ["Signature"])
        XCTAssertEqual(model.selectedBlankID, blank0.id, "first blank must be selected after plan")
        XCTAssertEqual(model.targetURL, target)
    }

    // MARK: - applyFill async: gating assertion (all blanks passed through)

    func testApplyFillPassesAllBlanksToFacade() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        let fieldID = profile.fields[0].id
        let target = URL(fileURLWithPath: "/tmp/form.pdf")
        model.targetURL = target

        // Mix of statuses: confirmed, proposed, unmatched, rejected.
        let confirmed = makeProposedBlank(fieldID: fieldID, value: "Acme Corp")
        var confirmedVar = confirmed
        confirmedVar.status = .confirmed
        let proposed = makeProposedBlank(fieldID: fieldID, value: "BVI")
        let unmatched = makeUnmatchedBlank()
        let rejected = makeRejectedBlank()
        model.blanks = [confirmedVar, proposed, unmatched, rejected]
        model.stage = .reviewing

        var capturedPlan: FillPlan?
        let fakeReport = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/out/form (filled).pdf"),
            filledCount: 1,
            skipped: []
        )
        FillModel.applyFillForTesting = { plan, _, _ in
            capturedPlan = plan
            return fakeReport
        }

        let outputDir = URL(fileURLWithPath: "/tmp/fill-out")
        await model.applyFill(outputDir: outputDir)

        XCTAssertEqual(model.stage, .done(fakeReport))

        // The model must pass ALL blanks (not pre-filter): the facade does the filtering.
        let passedBlanks = try XCTUnwrap(capturedPlan?.blanks)
        XCTAssertEqual(passedBlanks.count, 4, "model must pass all blanks; facade filters")
        XCTAssertTrue(passedBlanks.contains { $0.id == confirmedVar.id })
        XCTAssertTrue(passedBlanks.contains { $0.id == proposed.id })
        XCTAssertTrue(passedBlanks.contains { $0.id == unmatched.id })
        XCTAssertTrue(passedBlanks.contains { $0.id == rejected.id })
    }

    func testApplyFillFailureSetsFailedStage() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        model.targetURL = URL(fileURLWithPath: "/tmp/form.pdf")
        model.blanks = [makeProposedBlank(fieldID: profile.fields[0].id, value: "v")]
        model.stage = .reviewing

        struct FakeApplyError: Error {}
        FillModel.applyFillForTesting = { _, _, _ in throw FakeApplyError() }

        await model.applyFill(outputDir: URL(fileURLWithPath: "/tmp/out"))

        guard case .failed = model.stage else {
            XCTFail("stage must be .failed after apply error")
            return
        }
    }
}
