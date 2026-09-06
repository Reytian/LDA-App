//
//  FillModelLibraryTests.swift
//  LDACoreTests
//
//  Tests for FillModel's library-stage intents: refreshLibrary, createPortfolio,
//  addField, resolveFieldName, saveToLibrary (create and update round-trip),
//  deletePortfolio, openForEdit, exportPortfolio, importPortfolio, backToLibrary,
//  external-load / currentPortfolioID clearing, cached library instance, and
//  export failure preservation of library stage.
//
//  Split from FillModelTests.swift to respect the 800-line file cap.
//  The keychain-skip probe, workDir lifecycle, and makeLibrarySeam / makeCompanyPortfolio
//  helpers are duplicated from FillModelTests (deliberate: each test file is
//  intentionally self-contained; see FillServiceTests / DocxFillTests for the same
//  pattern).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelLibraryTests: XCTestCase {

    // MARK: - Per-test library root

    private var workDir: URL!

    // MARK: - Setup / teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Fail here if an earlier suite leaked a process-wide test seam.
        assertNoTestSeamsInstalled()

        // Probe the Keychain so library tests skip cleanly on unsigned processes.
        // Duplicated from FillModelTests (see file header for rationale).
        let probeService = "ai.openclaw.lda.libraryindexkey"
        let probeAccount = TestNamespace.keychainAccount("fillmodellibrary-probe")
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
            throw XCTSkip("Keychain unavailable in this test process (status \(addStatus)); skipping FillModelLibraryTests")
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
            .appendingPathComponent("FillModelLibraryTests-\(UUID().uuidString)", isDirectory: true)
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
        model.profile = makeCompanyPortfolio(label: "Retained Profile")
        model.targetURL = URL(fileURLWithPath: "/tmp/retained-target.pdf")
        await model.refreshLibrary()

        guard case .failed = model.stage else {
            XCTFail("stage must be .failed when library list() throws; got \(model.stage)")
            return
        }
        XCTAssertEqual(model.failureContext, .library,
            "a library failure must stay in the library despite retained workflow data")
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

    func testSuccessfulDeleteRetryClearsPriorLibraryFailure() async throws {
        let lib = try makeLibrarySeam()
        let id = try lib.create(makeCompanyPortfolio(label: "Retry Delete"))
        let model = FillModel(modelPath: nil)
        model.failureContext = .library
        model.stage = .failed("Transient library error")

        await model.deletePortfolio(id: id)

        XCTAssertEqual(model.stage, .library)
        XCTAssertNil(model.failureContext)
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
            .appendingPathComponent("FillModelLibraryTests-export-\(UUID().uuidString)", isDirectory: true)
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
        model.failureContext = .library
        model.stage = .failed("Transient import error")
        let importedID = await model.importPortfolio(from: exportURL, protection: .passphrase("test-pass"))

        XCTAssertNotNil(importedID, "importPortfolio must return the new UUID")
        XCTAssertNotEqual(importedID, id, "imported portfolio must have a new UUID")
        XCTAssertEqual(model.stage, .library)
        XCTAssertNil(model.failureContext)

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

    // MARK: - A stale extraction cannot overwrite another portfolio

    /// The review finding end to end, through the real library: extraction A
    /// is in flight, the user goes back to the library and opens B, then A
    /// finishes. The editor must still hold B, and the Save that follows must
    /// write B's own data under B's id, never A's.
    func testAStaleExtractionCannotBeSavedOverThePortfolioOpenedAfterIt() async throws {
        let lib = try makeLibrarySeam()
        let bID = try lib.create(makeCompanyPortfolio(label: "Portfolio B"))
        let portfolioA = makeCompanyPortfolio(label: "Portfolio A")
        let blocker = DispatchSemaphore(value: 0)
        FillModel.extractProfileForTesting = { _, _, _, _, _ in
            blocker.wait()
            return ExtractProfileResult(profile: portfolioA, failedSources: [])
        }

        let model = FillModel(modelPath: "/fake/model.gguf")
        await model.createPortfolio(
            kind: .company,
            label: "Portfolio A",
            fromScratch: false,
            createdAtISO8601: "2026-09-06T00:00:00Z"
        )
        let extracting = Task {
            await model.extractProfile(
                sources: [URL(fileURLWithPath: "/tmp/synthetic-source.txt")],
                label: "Portfolio A",
                createdAtISO8601: "2026-09-06T00:00:00Z"
            )
        }
        var waited = 0
        while model.stage != .importingSources && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertEqual(model.stage, .importingSources, "the extraction never started")

        model.backToLibrary()
        await model.openForEdit(id: bID)
        XCTAssertEqual(model.profile?.label, "Portfolio B", "fixture: B is open")

        blocker.signal()
        await extracting.value

        XCTAssertEqual(model.profile?.label, "Portfolio B", "A's profile landed in B's editor")
        XCTAssertEqual(model.currentPortfolioID, bID)
        XCTAssertFalse(model.profileDirty, "B was opened clean and nothing the user did changed it")

        await model.saveToLibrary(modifiedAtISO8601: "2026-09-06T00:01:00Z")
        XCTAssertEqual(
            try lib.load(id: bID).label, "Portfolio B",
            "portfolio B was overwritten with the stale extraction"
        )
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
        model.targetURL = URL(fileURLWithPath: "/tmp/retained-target.pdf")
        XCTAssertTrue(model.profileDirty, "precondition: dirty before save attempt")

        await model.saveToLibrary(modifiedAtISO8601: "2026-06-11T01:00:00Z")

        guard case .failed = model.stage else {
            XCTFail("stage must be .failed when saveToLibrary throws; got \(model.stage)")
            return
        }
        XCTAssertEqual(model.failureContext, .profile,
            "a save failure must stay in the editor even when a prior target is retained")
        XCTAssertTrue(model.profileDirty,
            "profileDirty must remain true after a failed save (nav guard: shell must not call backToLibrary)")

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: workDir.path
        )
        await model.saveToLibrary(modifiedAtISO8601: "2026-06-11T02:00:00Z")

        XCTAssertEqual(model.stage, .profileReady)
        XCTAssertNil(model.failureContext)
        XCTAssertFalse(model.profileDirty)
    }
}
