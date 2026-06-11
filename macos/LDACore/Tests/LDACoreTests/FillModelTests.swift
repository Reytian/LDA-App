//
//  FillModelTests.swift
//  LDACoreTests
//
//  Tests for the LDAUI FillModel view-model. They exercise synchronous intents
//  (accept, reject, repoint, field editing, conflict resolution, navigation),
//  async intent paths via injected fakes (extractProfile, planFill, applyFill),
//  the applyFill gating assertion (all blanks passed through to the facade),
//  and library-stage intents (refreshLibrary, createPortfolio, openForEdit,
//  addField, saveToLibrary, deletePortfolio, exportPortfolio, importPortfolio,
//  backToLibrary, resolveFieldName).
//
//  FillModel is @MainActor isolated; the suite is annotated @MainActor to match.
//  Fake service runners are wired via FillModel's static test-seam vars and
//  nilled out in tearDown, mirroring ReviewModelTests.
//
//  Library tests use the libraryForTesting seam with a real PortfolioLibrary over
//  a temp directory. The Keychain probe is duplicated from PortfolioLibraryTests
//  (choice: duplicate rather than extract to a shared helper to avoid creating a
//  new source file just for a ~20-line probe; the duplication is isolated and
//  self-documenting). A per-test workDir is created in setUpWithError and removed
//  in tearDownWithError. When the Keychain is unavailable the class-level
//  setUpWithError throws XCTSkip, which skips the entire run for that process.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Combine
import Security
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelTests: XCTestCase {

    // MARK: - Per-test library root

    private var workDir: URL!

    // MARK: - Setup / teardown

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Probe the Keychain so library tests skip cleanly on unsigned processes.
        // Duplicated from PortfolioLibraryTests (see file header for rationale).
        let probeService = "ai.openclaw.lda.libraryindexkey"
        let probeAccount = "fillmodel-test-probe-\(UUID().uuidString)"
        let probeData = Data("probe".utf8)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: probeData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        let tolerated: Set<OSStatus> = [
            errSecMissingEntitlement,
            errSecNotAvailable,
            errSecInteractionNotAllowed,
            errSecAuthFailed
        ]
        if tolerated.contains(addStatus) {
            throw XCTSkip("Keychain unavailable in this test process (status \(addStatus)); skipping FillModelTests")
        }
        if addStatus == errSecSuccess {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: probeAccount
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }

        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FillModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Clear all static test seams after every test so they never bleed.
        FillModel.extractProfileForTesting = nil
        FillModel.planFillForTesting = nil
        FillModel.applyFillForTesting = nil
        FillModel.libraryForTesting = nil
        FillModel.libraryRootForTesting = nil

        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil

        try super.tearDownWithError()
    }

    // MARK: - Library helpers

    /// Creates a PortfolioLibrary over workDir and injects it as the test seam.
    private func makeLibrarySeam() throws -> PortfolioLibrary {
        let lib = try PortfolioLibrary(rootDirectory: workDir)
        FillModel.libraryForTesting = lib
        return lib
    }

    /// A minimal company portfolio suitable for library round-trip tests.
    private func makeCompanyPortfolio(
        label: String = "Test Co",
        kind: PortfolioKind = .company,
        createdAt: String = "2026-06-11T00:00:00Z"
    ) -> ClientPortfolio {
        ClientPortfolio(
            label: label,
            fields: [
                ProfileField(
                    id: UUID(),
                    key: .companyName,
                    value: "Test Holdings Limited",
                    sourceDocument: "cert.pdf",
                    sourceSnippet: "Test Holdings Limited",
                    snippetVerified: true,
                    confidence: 0.95,
                    userEdited: false
                )
            ],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: createdAt,
            incomplete: false,
            kind: kind,
            modifiedAtISO8601: createdAt
        )
    }

    // MARK: - Helpers

    /// A minimal ClientPortfolio with two distinct fields.
    private func makeProfile(
        companyName: String = "Acme Corp",
        jurisdiction: String = "BVI"
    ) -> ClientPortfolio {
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
        return ClientPortfolio(
            label: "Test Co",
            fields: [f1, f2],
            sourceDocuments: ["test.txt"],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false
        )
    }

    /// A profile with a conflict: two .companyName fields with different values.
    private func makeConflictedProfile() -> ClientPortfolio {
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
        return ClientPortfolio(
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

        FillModel.extractProfileForTesting = { _, _, _, _, _ in fakeResult }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Test Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertEqual(model.profile, profile)
        // After extraction, profileDirty must be true: the extracted-but-not-yet-saved
        // portfolio is unsaved work. loadProfile clears dirty by design (it is the
        // "load a clean saved copy" path), but extractProfile immediately re-sets dirty
        // when fields were produced so Save-to-library is enabled and Back-to-Library
        // shows a discard confirmation. Changed from false -> true (fix: portal save gating).
        XCTAssertTrue(model.profileDirty, "extraction result is unsaved work: dirty must be true")
        // One failed source must surface as a warning.
        XCTAssertEqual(model.sourceWarnings.count, 1)
        XCTAssertTrue(model.sourceWarnings[0].contains("bad.txt"))
    }

    func testExtractProfileFailureSetsFailedStageWithMessage() async throws {
        let model = FillModel(modelPath: "/fake/model.gguf")

        struct FakeError: Error {
            let msg: String
        }
        FillModel.extractProfileForTesting = { _, _, _, _, _ in
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

    // MARK: - extractProfile: dirty after extraction with fields (fix 1a)

    func testExtractProfileSuccessWithFieldsLeavesDirtyTrue() async throws {
        // extractProfile must leave profileDirty true when the result contains fields,
        // because the portfolio has not been saved to the library yet.
        let model = FillModel(modelPath: "/fake/model.gguf")
        let profile = makeProfile() // has 2 fields
        XCTAssertFalse(profile.fields.isEmpty, "precondition: fixture profile has fields")
        let fakeResult = ExtractProfileResult(profile: profile, failedSources: [])

        FillModel.extractProfileForTesting = { _, _, _, _, _ in fakeResult }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Test Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertTrue(model.profileDirty,
            "profileDirty must be true after extraction: extracted portfolio is unsaved work")
    }

    func testExtractProfileSuccessWithNoFieldsLeavesClean() async throws {
        // extractProfile with an empty result profile should NOT mark dirty,
        // since there is nothing new to save.
        let model = FillModel(modelPath: "/fake/model.gguf")
        let emptyProfile = ClientPortfolio(
            label: "Empty Co",
            fields: [],
            sourceDocuments: [],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false
        )
        let fakeResult = ExtractProfileResult(profile: emptyProfile, failedSources: [])

        FillModel.extractProfileForTesting = { _, _, _, _, _ in fakeResult }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Empty Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertFalse(model.profileDirty,
            "profileDirty must stay false when extraction produced no fields (nothing to save)")
    }

    func testBackToLibraryDialogGatedOnDirtyAfterExtraction() async throws {
        // After successful extraction with fields, profileDirty is true.
        // This is the condition that gates the "Back to Library" discard confirmation:
        // FillShell.requestBackToLibrary checks profileDirty directly.
        // This model-level test pins the contract so any regression that stops
        // dirty being set after extraction will be caught here.
        let model = FillModel(modelPath: "/fake/model.gguf")
        let profile = makeProfile()
        let fakeResult = ExtractProfileResult(profile: profile, failedSources: [])
        FillModel.extractProfileForTesting = { _, _, _, _, _ in fakeResult }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Test Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        XCTAssertTrue(model.profileDirty,
            "profileDirty must be true after extraction so the Back-to-Library discard dialog is shown")
    }

    // MARK: - saveToLibrary failure guard (fix 2)

    func testSaveToLibraryFailureLeavesStageFailedAndDirtyTrue() async throws {
        // When saveToLibrary fails (e.g. library root unreadable), stage becomes
        // .failed and profileDirty remains true. The shell must NOT call backToLibrary
        // in this case.
        let lib = try makeLibrarySeam()
        _ = try lib.create(makeCompanyPortfolio())

        // Make the directory unreadable so the save throws.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: workDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: workDir.path
            )
        }

        let model = FillModel(modelPath: nil)
        // Set up an unsaved portfolio.
        await model.createPortfolio(
            kind: .company,
            label: "Save Fail Co",
            fromScratch: true,
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )
        model.addField(key: .companyName, value: "Save Fail Holdings")
        XCTAssertTrue(model.profileDirty, "precondition: dirty before save attempt")

        await model.saveToLibrary(modifiedAtISO8601: "2026-06-11T01:00:00Z")

        guard case .failed = model.stage else {
            XCTFail("stage must be .failed when saveToLibrary throws; got \(model.stage)")
            return
        }
        XCTAssertTrue(model.profileDirty,
            "profileDirty must remain true after a failed save (nav guard: shell must not call backToLibrary)")
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

        FillModel.planFillForTesting = { _, _ in fakePlan }

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

    // MARK: - I1: planFill seam receives the live profile

    func testPlanFillSeamReceivesLoadedProfile() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile(companyName: "SeamCheck Corp")
        model.loadProfile(profile)

        var receivedProfile: ClientPortfolio?
        let fakePlan = FillPlan(
            targetFormat: .pdf,
            blanks: [],
            manualWidgetNames: []
        )
        FillModel.planFillForTesting = { _, handedProfile in
            receivedProfile = handedProfile
            return fakePlan
        }

        await model.planFill(target: URL(fileURLWithPath: "/tmp/form.pdf"))

        let handed = try XCTUnwrap(receivedProfile, "seam must receive the live profile")
        XCTAssertEqual(handed.label, profile.label)
        XCTAssertEqual(handed.fields.count, profile.fields.count)
        XCTAssertEqual(handed.fields[0].value, "SeamCheck Corp",
                       "seam must receive the profile loaded into the model")
    }

    // MARK: - I2: applyFill from .done is a no-op (report not overwritten)

    func testApplyFillFromDoneIsNoOp() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        model.targetURL = URL(fileURLWithPath: "/tmp/form.pdf")
        model.blanks = [makeProposedBlank(fieldID: profile.fields[0].id, value: "v")]

        // Put the model in .done with the original report.
        let originalReport = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/out/form (filled).pdf"),
            filledCount: 3,
            skipped: []
        )
        model.stage = .done(originalReport)

        // Wire a seam that would return a different report if called.
        var seamCallCount = 0
        FillModel.applyFillForTesting = { _, _, _ in
            seamCallCount += 1
            return FillReport(
                outputURL: URL(fileURLWithPath: "/tmp/out/overwrite.pdf"),
                filledCount: 0,
                skipped: []
            )
        }

        await model.applyFill(outputDir: URL(fileURLWithPath: "/tmp/out"))

        // The seam must never have been called.
        XCTAssertEqual(seamCallCount, 0, "applyFill from .done must not invoke the facade")
        // The stage must remain .done with the original report unchanged.
        guard case .done(let report) = model.stage else {
            XCTFail("stage must remain .done; got \(model.stage)")
            return
        }
        XCTAssertEqual(report.filledCount, 3, "original report must not be overwritten")
    }

    // MARK: - M2: re-accepting the same nil-proposal blank re-signals pickerRequestID

    func testReacceptSameAmbiguousBlankResignals() throws {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())
        let blank = makeAmbiguousBlank()
        model.blanks = [blank]

        // Collect all published values of pickerRequestID via Combine.
        var publishedIDs: [UUID?] = []
        let cancellable = model.$pickerRequestID.sink { publishedIDs.append($0) }
        defer { cancellable.cancel() }

        // First acceptance: nil -> id.
        model.acceptBlank(id: blank.id)
        // Second acceptance of the same blank: must nil -> id again.
        model.acceptBlank(id: blank.id)

        // Expected sequence: initial nil (from sink subscription) + nil + id (first
        // accept) + nil + id (second accept) = 5 events.
        // We assert the minimum: the sequence ends with ...nil, id so the second
        // accept fired a fresh transition.
        XCTAssertGreaterThanOrEqual(publishedIDs.count, 4,
            "must see at least initial + nil + id + nil + id across two acceptances")
        // Last two published values must be nil then the blank id.
        let last = publishedIDs.suffix(2)
        XCTAssertEqual(Array(last), [nil, blank.id],
            "second accept must re-signal nil -> id so .onChange observers re-fire")
    }

    // MARK: - targetText: real facade path publishes document text

    /// planFill via the real DocxImporter (no seam) populates targetText with
    /// the fixture document content. modelPath nil keeps the planner deterministic.
    func testPlanFillDocxRealFacadePublishesTargetText() async throws {
        // Build a minimal fixture DOCX on disk and run planFill without a seam
        // so the real DocxImporter path executes.
        let docxURL = try writeFixtureDocx("Acme Corp enters this agreement.")

        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())

        // Use the real planFill path (seam is nil).
        await model.planFill(target: docxURL)

        // The plan may reach .reviewing or .failed depending on whether
        // LDAFillService finds blanks; what matters here is that targetText
        // was populated with the fixture text (best-effort display import).
        let text = try XCTUnwrap(model.targetText,
            "targetText must be non-nil for a real docx target after planFill")
        XCTAssertTrue(text.contains("Acme Corp"),
            "targetText must contain the fixture document text; got: \(text)")
    }

    /// A seam-driven planFill with a nonexistent target URL must leave
    /// targetText nil without failing (display import tolerates missing files).
    func testPlanFillSeamWithNonexistentURLLeavesTargetTextNil() async throws {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())

        let fakePlan = FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: [])
        FillModel.planFillForTesting = { _, _ in fakePlan }

        // A URL that does not exist on disk; DocxImporter will throw, leaving
        // targetText nil. The .docx extension triggers the import attempt.
        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).docx")
        await model.planFill(target: fakeURL)

        XCTAssertEqual(model.stage, .reviewing, "stage must reach .reviewing via seam")
        XCTAssertNil(model.targetText,
            "targetText must be nil when the target file does not exist on disk")
    }

    // MARK: - Fixture builder for targetText tests
    //
    // Deliberately self-contained: does not share helpers with DocxFillTests.
    // See DocxFillTests.writeFixtureDocx for the original reference pattern.

    private static let fixtureContentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let fixtureRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private func writeFixtureDocx(_ bodyText: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-fillmodel-\(UUID().uuidString).docx")
        let encoded = bodyText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">\(encoded)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.fixtureContentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.fixtureRelsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Security-scope lifecycle bookkeeping

    // The real security-scoped resource machinery (startAccessingSecurityScopedResource /
    // stopAccessingSecurityScopedResource) is a sandbox API and behaves as a no-op
    // outside the sandboxed .app: startAccessing returns false, so targetScopeActive
    // stays false throughout the test run. What we can observe from outside the
    // sandbox is the MODEL-LEVEL bookkeeping: scopedTargetURL is set during
    // planFill and cleared after applyFill (or after a failure).
    //
    // These tests assert that the model's internal scope-tracking variables are
    // updated at the correct lifecycle points. This pins the implementation
    // contract so a regression (e.g. scope never released, or released too early)
    // will be caught even without a real sandbox.
    //
    // Note: targetScopeActive is always false in tests (no sandbox), so we only
    // assert on scopedTargetURL (which is always updated regardless of the
    // startAccessing return value).

    func testPlanFillSetsScopedTargetURL() async throws {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())

        let fakePlan = FillPlan(targetFormat: .pdf, blanks: [], manualWidgetNames: [])
        FillModel.planFillForTesting = { _, _ in fakePlan }

        let target = URL(fileURLWithPath: "/tmp/scope-test-plan.pdf")
        await model.planFill(target: target)

        // After a successful planFill the model must hold the scoped URL so
        // applyFill can still access the file (scope survives planFill).
        XCTAssertEqual(model.scopedTargetURL, target,
            "scopedTargetURL must be set to the target after planFill succeeds")
    }

    func testApplyFillClearsScopedTargetURL() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)
        let target = URL(fileURLWithPath: "/tmp/scope-test-apply.pdf")
        model.targetURL = target
        model.blanks = [makeProposedBlank(fieldID: profile.fields[0].id, value: "v")]
        model.stage = .reviewing

        // Simulate: scope was opened by planFill.
        // We set the URL directly to mirror the state planFill would leave behind.
        model.scopedTargetURL = target

        let fakeReport = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/out/scope-test-apply (filled).pdf"),
            filledCount: 1,
            skipped: []
        )
        FillModel.applyFillForTesting = { _, _, _ in fakeReport }

        await model.applyFill(outputDir: URL(fileURLWithPath: "/tmp/out"))

        XCTAssertEqual(model.stage, .done(fakeReport))
        XCTAssertNil(model.scopedTargetURL,
            "scopedTargetURL must be cleared after applyFill completes")
    }

    func testPlanFillFailureClearsScopedTargetURL() async throws {
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())

        struct FakePlanError: Error {}
        FillModel.planFillForTesting = { _, _ in throw FakePlanError() }

        let target = URL(fileURLWithPath: "/tmp/scope-test-fail.pdf")
        await model.planFill(target: target)

        guard case .failed = model.stage else {
            XCTFail("stage must be .failed after planFill error")
            return
        }
        XCTAssertNil(model.scopedTargetURL,
            "scopedTargetURL must be cleared when planFill fails (nothing left to apply)")
    }

    func testOpeningNewTargetReplacesScopedTargetURL() async throws {
        // Two successive planFill calls: the second must replace the first's scope,
        // not accumulate a second one.
        let model = FillModel(modelPath: nil)
        model.loadProfile(makeProfile())

        let fakePlan = FillPlan(targetFormat: .pdf, blanks: [], manualWidgetNames: [])
        FillModel.planFillForTesting = { _, _ in fakePlan }

        let first  = URL(fileURLWithPath: "/tmp/scope-first.pdf")
        let second = URL(fileURLWithPath: "/tmp/scope-second.pdf")

        await model.planFill(target: first)
        XCTAssertEqual(model.scopedTargetURL, first)

        await model.planFill(target: second)
        XCTAssertEqual(model.scopedTargetURL, second,
            "scope must track the most recent target; old scope replaced by new one")
    }

    // MARK: - Regression guard: planFill is invocable from .profileReady (unreachable-UI fix)

    /// Regression guard for the fill-review-unreachable bug: after the user builds
    /// or loads a profile (stage .profileReady), planFill must be callable without
    /// any stage guard blocking the transition. Stage must advance to .reviewing
    /// after the seam returns successfully.
    ///
    /// Previously, the "Open Target" button lived only in fillReviewToolbar (stages
    /// .planning / .reviewing / ...), making steps 4-6 of the workflow dead UI.
    /// This test pins that planFill is usable from .profileReady so any regression
    /// that re-introduces a stage guard will fail here.
    func testPlanFillIsInvocableFromProfileReadyAndTransitionsToReviewing() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        model.loadProfile(profile)

        // Confirm we are starting from .profileReady.
        XCTAssertEqual(model.stage, .profileReady,
            "precondition: loadProfile must land in .profileReady")

        let fakePlan = FillPlan(
            targetFormat: .pdf,
            blanks: [makeProposedBlank(fieldID: profile.fields[0].id, value: "Acme Corp")],
            manualWidgetNames: []
        )
        FillModel.planFillForTesting = { _, _ in fakePlan }

        await model.planFill(target: URL(fileURLWithPath: "/tmp/form.pdf"))

        XCTAssertEqual(model.stage, .reviewing,
            "planFill invoked from .profileReady must transition stage to .reviewing")
        XCTAssertEqual(model.blanks.count, 1,
            "blanks from the plan must be published after transition")
    }

    // MARK: - Item 3: planFill with explicit bad modelPath throws (loud failure)

    /// When modelPath is explicitly supplied and points to a nonexistent file,
    /// planFill must throw rather than silently falling back to synonym-only
    /// matching. A typo in the model path should be loud.
    ///
    /// This test exercises the FillModel layer: it wires no seam for planFill
    /// (so the real LDAFillService.planFill runs), passes a nonexistent GGUF path,
    /// and asserts the model lands in .failed rather than .reviewing.
    ///
    /// The test uses a DOCX fixture with no "[...]-style" blanks so that Pass 1
    /// (synonym-only) produces at least one .unmatched blank, which is the
    /// condition that triggers the model-load pass. The blank is injected via a
    /// specially named AcroForm-style context: we use a PDF fixture via the real
    /// service to keep the test self-contained -- but since FillModel calls
    /// LDAFillService which needs a real file, we use the planFillForTesting seam
    /// set to nil and rely on LDAFillService directly by NOT setting the seam,
    /// passing a fake target path that LDAFillService will reject before reaching
    /// the model-load step.
    ///
    /// Simpler and more honest approach: test LDAFillService.planFill directly in
    /// FillServiceTests (see testPlanFillWithExplicitBadModelPathThrows). Here we
    /// test the FillModel propagation: model.failed stage on planFill throw.
    func testPlanFillModelFailureSetsFailedStage() async throws {
        let model = FillModel(modelPath: "/nonexistent/model.gguf")
        model.loadProfile(makeProfile())

        // Wire the seam to throw an engine-load-style error, simulating what
        // LDAFillService.planFill now throws when modelPath is bad and unmatched
        // blanks remain.
        struct FakeEngineError: Error, LocalizedError {
            var errorDescription: String? { "Could not load model at /nonexistent/model.gguf" }
        }
        FillModel.planFillForTesting = { _, _ in throw FakeEngineError() }

        await model.planFill(target: URL(fileURLWithPath: "/tmp/form.pdf"))

        guard case .failed(let msg) = model.stage else {
            XCTFail("stage must be .failed when planFill throws; got \(model.stage)")
            return
        }
        XCTAssertFalse(msg.isEmpty, "failure message must not be empty")
    }

    // MARK: - M1/d: importingSources -> extracting on first progress callback

    func testExtractProfileStageFlipsToExtractingOnFirstProgress() async throws {
        let model = FillModel(modelPath: nil)
        let profile = makeProfile()
        let fakeResult = ExtractProfileResult(profile: profile, failedSources: [])

        // Stage sequence captured from main-actor context (seam runs on detached thread).
        // We capture stages from the published property using Combine.
        var stageSequence: [FillStage] = []
        var cancellable: AnyCancellable?

        // Wire the seam to fire the first progress callback, which should flip
        // the stage from .importingSources to .extracting.
        FillModel.extractProfileForTesting = { _, _, _, _, onProgress in
            // Fire the "extraction started" signal: done=0, total=5.
            onProgress(0, 5)
            return fakeResult
        }

        cancellable = model.$stage.sink { stageSequence.append($0) }
        defer { cancellable?.cancel() }

        await model.extractProfile(
            sources: [URL(fileURLWithPath: "/tmp/source.txt")],
            label: "Test Co",
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        cancellable?.cancel()

        // Must pass through importingSources before extracting.
        XCTAssertTrue(stageSequence.contains(.importingSources),
            "stage must pass through .importingSources at the start")
        XCTAssertTrue(stageSequence.contains(.extracting),
            "stage must flip to .extracting after the first progress callback")

        // importingSources must come before extracting in the sequence.
        let importingIdx = stageSequence.firstIndex(of: .importingSources)
        let extractingIdx = stageSequence.firstIndex(of: .extracting)
        if let i = importingIdx, let e = extractingIdx {
            XCTAssertLessThan(i, e, ".importingSources must precede .extracting")
        }

        // Final stage must be .profileReady.
        XCTAssertEqual(model.stage, .profileReady)
    }

    // MARK: - Library: refreshLibrary publishes sorted summaries and stage .library

    func testRefreshLibraryPublishesSortedSummariesAndStageLibrary() async throws {
        let lib = try makeLibrarySeam()
        let p1 = makeCompanyPortfolio(label: "Zeta Corp")
        let p2 = makeCompanyPortfolio(label: "Alpha Inc")
        _ = try lib.create(p1)
        _ = try lib.create(p2)

        let model = FillModel(modelPath: nil)
        await model.refreshLibrary()

        XCTAssertEqual(model.stage, .library, "stage must be .library after refreshLibrary")
        XCTAssertEqual(model.summaries.count, 2)
        XCTAssertEqual(model.summaries[0].label, "Alpha Inc", "summaries must be sorted alphabetically")
        XCTAssertEqual(model.summaries[1].label, "Zeta Corp")
    }

    // MARK: - Library: refreshLibrary failure path -> .failed

    func testRefreshLibraryFailureSetsFailed() async throws {
        // Inject a library backed by a workDir that we then make unreadable.
        let lib = try makeLibrarySeam()
        _ = try lib.create(makeCompanyPortfolio())

        // Make the directory unreadable so list() throws.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: workDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: workDir.path
            )
        }

        let model = FillModel(modelPath: nil)
        await model.refreshLibrary()

        guard case .failed = model.stage else {
            XCTFail("stage must be .failed when library list() throws; got \(model.stage)")
            return
        }
    }

    // MARK: - Library: libraryNotice set when reconciliation happened

    func testLibraryNoticeSetWhenReconciliationHappened() async throws {
        let lib = try makeLibrarySeam()
        _ = try lib.create(makeCompanyPortfolio(label: "Reconcile Me"))

        // Delete the index file to force reconciliation on the next list().
        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        try FileManager.default.removeItem(at: indexFile)

        let model = FillModel(modelPath: nil)
        await model.refreshLibrary()

        XCTAssertEqual(model.stage, .library)
        XCTAssertNotNil(model.libraryNotice,
            "libraryNotice must be set when lastListReconciled is true")
    }

    // MARK: - Library: createPortfolio fromScratch yields empty editable portfolio

    func testCreatePortfolioFromScratchYieldsEmptyEditablePortfolio() async throws {
        _ = try makeLibrarySeam()

        let model = FillModel(modelPath: nil)
        await model.createPortfolio(
            kind: .individual,
            label: "Jane Doe",
            fromScratch: true,
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        XCTAssertEqual(model.stage, .profileReady, "stage must be .profileReady after createPortfolio")
        XCTAssertNil(model.currentPortfolioID, "currentPortfolioID must be nil before first save")
        XCTAssertTrue(model.profileDirty, "profileDirty must be true for a new unsaved portfolio")
        let profile = try XCTUnwrap(model.profile, "profile must be non-nil after createPortfolio")
        XCTAssertEqual(profile.kind, .individual, "profile kind must match the requested kind")
        XCTAssertEqual(profile.label, "Jane Doe", "profile label must match")
        XCTAssertTrue(profile.fields.isEmpty, "fromScratch portfolio must have no fields")
    }

    // MARK: - Library: addField resolves canonical and custom keys

    func testAddFieldResolvesCanonicalAndCustomKeys() async throws {
        _ = try makeLibrarySeam()
        let model = FillModel(modelPath: nil)
        await model.createPortfolio(
            kind: .company,
            label: "Field Test Co",
            fromScratch: true,
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )

        // "email" resolves to canonical .email
        model.addField(key: ProfileFieldKey(rawKey: "email"), value: "test@example.com")

        // "sealNumber" is not canonical, becomes .custom("sealNumber")
        model.addField(key: ProfileFieldKey(rawKey: "sealNumber"), value: "SN-42")

        let profile = try XCTUnwrap(model.profile)
        XCTAssertEqual(profile.fields.count, 2)

        let emailField = profile.fields.first { $0.key == .email }
        XCTAssertNotNil(emailField, "email field must be present after addField(key: .email)")
        XCTAssertEqual(emailField?.value, "test@example.com")
        XCTAssertEqual(emailField?.sourceDocument, "manual entry")
        XCTAssertTrue(emailField?.userEdited == true)
        XCTAssertEqual(emailField?.confidence, 1.0)

        let sealField = profile.fields.first { $0.key == .custom("sealNumber") }
        XCTAssertNotNil(sealField, "custom sealNumber field must be present")
        XCTAssertEqual(sealField?.value, "SN-42")

        XCTAssertTrue(model.profileDirty)
    }

    // MARK: - Library: resolveFieldName canonical and custom

    func testResolveFieldNameCanonicalAndCustom() async throws {
        _ = try makeLibrarySeam()
        let model = FillModel(modelPath: nil)

        let emailKey = model.resolveFieldName("email")
        XCTAssertEqual(emailKey, .email, "'email' must resolve to canonical .email")

        let sealKey = model.resolveFieldName("sealNumber")
        XCTAssertEqual(sealKey, .custom("sealNumber"), "'sealNumber' must resolve to .custom(\"sealNumber\")")
    }

    // MARK: - Library: saveToLibrary create-then-update round trip

    func testSaveToLibraryCreateThenUpdateRoundTrip() async throws {
        let lib = try makeLibrarySeam()
        let model = FillModel(modelPath: nil)

        // Create a new from-scratch portfolio.
        await model.createPortfolio(
            kind: .company,
            label: "Round Trip Co",
            fromScratch: true,
            createdAtISO8601: "2026-06-11T00:00:00Z"
        )
        model.addField(key: .companyName, value: "Round Trip Holdings")

        // First save: assigns currentPortfolioID.
        await model.saveToLibrary(modifiedAtISO8601: "2026-06-11T01:00:00Z")

        let firstID = try XCTUnwrap(model.currentPortfolioID,
            "currentPortfolioID must be assigned after first save")
        XCTAssertFalse(model.profileDirty, "profileDirty must be cleared after save")
        XCTAssertEqual(model.stage, .profileReady, "stage must remain .profileReady after save")

        // Verify the portfolio exists in the library.
        let afterFirst = try lib.load(id: firstID)
        XCTAssertEqual(afterFirst.label, "Round Trip Co")

        // Second save: updates the existing entry.
        model.addField(key: .jurisdiction, value: "BVI")
        await model.saveToLibrary(modifiedAtISO8601: "2026-06-11T02:00:00Z")

        let secondID = try XCTUnwrap(model.currentPortfolioID)
        XCTAssertEqual(secondID, firstID, "ID must be stable across saves")
        XCTAssertFalse(model.profileDirty)

        // The summary's modifiedAt must reflect the second save timestamp.
        let summaries = model.summaries
        let summary = try XCTUnwrap(summaries.first { $0.id == firstID })
        XCTAssertEqual(summary.modifiedAtISO8601, "2026-06-11T02:00:00Z",
            "summary modifiedAt must reflect the second save timestamp")

        // The library must store 2 fields now.
        let afterSecond = try lib.load(id: firstID)
        XCTAssertEqual(afterSecond.fields.count, 2)
    }

    // MARK: - Library: deletePortfolio of the open portfolio returns .library and clears id

    func testDeletePortfolioOfOpenPortfolioReturnsLibraryAndClearsID() async throws {
        let lib = try makeLibrarySeam()
        let portfolio = makeCompanyPortfolio(label: "To Delete")
        let id = try lib.create(portfolio)

        let model = FillModel(modelPath: nil)

        // Open the portfolio for edit so currentPortfolioID is set.
        await model.openForEdit(id: id)
        XCTAssertEqual(model.currentPortfolioID, id, "precondition: currentPortfolioID set")
        XCTAssertEqual(model.stage, .profileReady)

        // Delete it.
        await model.deletePortfolio(id: id)

        XCTAssertEqual(model.stage, .library,
            "stage must be .library after deleting the currently open portfolio")
        XCTAssertNil(model.currentPortfolioID,
            "currentPortfolioID must be cleared after deleting the open portfolio")
        XCTAssertTrue(model.summaries.isEmpty,
            "summaries must be empty after deleting the only portfolio")
    }

    // MARK: - Library: openForEdit loads the saved portfolio

    func testOpenForEditLoadsTheSavedPortfolio() async throws {
        let lib = try makeLibrarySeam()
        let portfolio = makeCompanyPortfolio(label: "Load Me")
        let id = try lib.create(portfolio)

        let model = FillModel(modelPath: nil)
        await model.openForEdit(id: id)

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertEqual(model.currentPortfolioID, id)
        XCTAssertFalse(model.profileDirty, "profileDirty must be false after loading an existing portfolio")
        let loaded = try XCTUnwrap(model.profile)
        XCTAssertEqual(loaded.label, "Load Me")
        XCTAssertEqual(loaded.kind, .company)
        XCTAssertEqual(loaded.fields.count, portfolio.fields.count)
    }

    // MARK: - Library: export/import round trip through the model

    func testExportImportRoundTripThroughModel() async throws {
        let lib = try makeLibrarySeam()
        let portfolio = makeCompanyPortfolio(label: "Export Me")
        let id = try lib.create(portfolio)

        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FillModelTests-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }

        let exportURL = exportDir.appendingPathComponent("export.ldaprofile")

        let model = FillModel(modelPath: nil)

        // Export the portfolio.
        await model.exportPortfolio(id: id, to: exportURL, protection: .passphrase("test-pass"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path),
            "export file must exist after exportPortfolio")

        // Delete the original and import from the export file.
        try lib.delete(id: id)
        let importedID = await model.importPortfolio(from: exportURL, protection: .passphrase("test-pass"))

        XCTAssertNotNil(importedID, "importPortfolio must return the new UUID")
        XCTAssertNotEqual(importedID, id, "imported portfolio must have a new UUID")

        // Verify summaries were refreshed.
        XCTAssertEqual(model.summaries.count, 1)
        XCTAssertEqual(model.summaries[0].label, "Export Me")
    }

    // MARK: - Library: backToLibrary clears pickerRequestID and transient state

    func testBackToLibraryRestoresLibraryStage() async throws {
        _ = try makeLibrarySeam()
        let model = FillModel(modelPath: nil)
        model.pickerRequestID = UUID()
        model.stage = .profileReady

        model.backToLibrary()

        XCTAssertEqual(model.stage, .library, "backToLibrary must set stage to .library")
        XCTAssertNil(model.pickerRequestID, "backToLibrary must clear pickerRequestID")
    }

    // MARK: - External "Load Profile" clears currentPortfolioID (fix 4c)

    /// When an external .ldaprofile file is loaded via confirmLoadProfile, the shell
    /// clears model.currentPortfolioID so that a subsequent Save creates a NEW library
    /// entry instead of overwriting whatever portfolio was open before the load.
    ///
    /// This test pins the model contract: after loadProfile is called while
    /// currentPortfolioID is non-nil, the shell sets it to nil BEFORE calling
    /// loadProfile so Save always creates a fresh entry for an externally loaded file.
    ///
    /// We test the model-level mechanic directly (setting currentPortfolioID = nil
    /// then calling loadProfile) because the sheet logic lives in FillShellSheets
    /// and the contract is that nil currentPortfolioID + non-nil profile means
    /// saveToLibrary will always call create() rather than save().
    func testExternalLoadClearsCurrentPortfolioIDSoSaveCreatesNewEntry() async throws {
        let lib = try makeLibrarySeam()
        let existing = makeCompanyPortfolio(label: "Open Portfolio")
        let existingID = try lib.create(existing)

        let model = FillModel(modelPath: nil)

        // Simulate: the user has an existing portfolio open for editing.
        await model.openForEdit(id: existingID)
        XCTAssertEqual(model.currentPortfolioID, existingID,
            "precondition: currentPortfolioID must be set after openForEdit")

        // Simulate confirmLoadProfile: clear currentPortfolioID then call loadProfile.
        // (The real sheet code does this to prevent overwriting the open portfolio.)
        model.currentPortfolioID = nil
        let externalProfile = makeCompanyPortfolio(label: "Externally Loaded Portfolio")
        model.loadProfile(externalProfile)

        XCTAssertNil(model.currentPortfolioID,
            "currentPortfolioID must be nil after external load so Save creates a new entry")
        XCTAssertEqual(model.profile?.label, "Externally Loaded Portfolio")

        // Saving must create a NEW library entry, not overwrite the original.
        model.addField(key: .jurisdiction, value: "Cayman")
        await model.saveToLibrary(modifiedAtISO8601: "2026-06-11T01:00:00Z")

        let newID = try XCTUnwrap(model.currentPortfolioID,
            "currentPortfolioID must be assigned after first save of external profile")
        XCTAssertNotEqual(newID, existingID,
            "Save after external load must create a new library entry, not overwrite the open portfolio")

        // The original portfolio must be unmodified.
        let originalReloaded = try lib.load(id: existingID)
        XCTAssertEqual(originalReloaded.label, "Open Portfolio",
            "The original portfolio must not be modified by saving the externally loaded profile")
    }

    // MARK: - Library: cached instance is stable across intents

    /// Two successive refreshLibrary calls on the same model must use the same
    /// PortfolioLibrary instance. The production path is exercised by setting
    /// libraryRootForTesting (so the real Application Support directory is never
    /// touched) and leaving libraryForTesting nil so resolveLibrary() takes the
    /// construct-and-cache branch on the first call and the cache-hit branch on
    /// the second.
    func testLibraryInstanceIsCachedAcrossIntents() async throws {
        // Set the root override so the real Application Support is not used.
        FillModel.libraryRootForTesting = workDir

        let model = FillModel(modelPath: nil)

        // First intent: constructs and caches.
        await model.refreshLibrary()
        XCTAssertEqual(model.stage, .library, "stage must be .library after first refreshLibrary")
        let firstInstance = model._library

        // Second intent: must return the cached instance, not a new one.
        await model.refreshLibrary()
        XCTAssertEqual(model.stage, .library, "stage must be .library after second refreshLibrary")
        let secondInstance = model._library

        let first = try XCTUnwrap(firstInstance, "_library must be non-nil after first refreshLibrary")
        let second = try XCTUnwrap(secondInstance, "_library must be non-nil after second refreshLibrary")
        XCTAssertTrue(
            ObjectIdentifier(first) == ObjectIdentifier(second),
            "_library must be the same instance across successive intents"
        )
    }

    // MARK: - Library: export failure preserves library stage

    /// When exportPortfolio throws (destination is inside the library directory,
    /// which PortfolioLibrary rejects), the stage must remain .library and
    /// exportError must be non-nil. The user is not evicted from the list.
    func testExportFailurePreservesLibraryStage() async throws {
        let lib = try makeLibrarySeam()
        let portfolio = makeCompanyPortfolio(label: "Export Fail Co")
        let id = try lib.create(portfolio)

        let model = FillModel(modelPath: nil)
        await model.refreshLibrary()
        XCTAssertEqual(model.stage, .library, "precondition: stage must be .library")

        // Exporting to a path inside the library root triggers
        // PortfolioLibraryError.exportDestinationInsideLibrary (assertNotInsideLibrary).
        // workDir is the library root, so any path under it is rejected.
        let badDestination = workDir.appendingPathComponent("inside-library.ldaprofile")

        await model.exportPortfolio(id: id, to: badDestination, protection: .passphrase("test"))

        XCTAssertEqual(model.stage, .library,
            "stage must remain .library after export failure (user must not be evicted)")
        XCTAssertNotNil(model.exportError,
            "exportError must be non-nil after a failed export")
    }
}

