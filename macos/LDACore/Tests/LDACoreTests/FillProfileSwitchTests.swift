//
//  FillProfileSwitchTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F14. Fill kept one client's staged sources when another
//  profile was opened: sourcePaths was cleared only by createPortfolio, so
//  after opening profile B from the library, Re-extract from Sources ran over
//  client A's documents and overwrote B. The rest of A's transient state (the
//  extraction warnings and progress, the plan for A's target) stayed too.
//
//  Opening or loading another profile, creating one, and going back to the
//  library now clear the staged sources and the other per-profile transient
//  state. Landing an extraction keeps the sources it ran over.
//
//  Hermetic: no Portfolio library is read (it is sealed in the Keychain). The
//  open is pointed at a library root that cannot be created, so it fails
//  before any read, and what client A staged must already be gone by then.
//  Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillProfileSwitchTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FillProfileSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FillModel.libraryRootForTesting = nil
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func portfolio(_ label: String) -> ClientPortfolio {
        ClientPortfolio(
            label: label,
            fields: [],
            sourceDocuments: [],
            createdAtISO8601: "2026-11-11T00:00:00Z",
            incomplete: false,
            kind: .company,
            modifiedAtISO8601: "2026-11-11T00:00:00Z"
        )
    }

    /// The editor holding client A, with everything a session of A stages.
    private func editorHoldingClientA() -> FillModel {
        let model = FillModel(modelPath: nil)
        model.loadProfile(portfolio("Client A"))
        model.currentPortfolioID = UUID()
        model.sourcePaths = [workDir.appendingPathComponent("client-a-certificate.pdf")]
        model.sourceFailures = [FillSourceFailure(name: "client-a-bank.pdf", reason: "unreadable")]
        model.progress = 1
        let blank = Blank(
            location: .textSpan(start: 0, end: 4),
            label: "Name",
            context: "Name: ____",
            proposedFieldID: nil,
            proposedValue: "Client A Holdings",
            status: .proposed
        )
        model.blanks = [blank]
        model.selectedBlankID = blank.id
        model.pickerRequestID = blank.id
        let target = workDir.appendingPathComponent("client-a-form.docx")
        model.targetURL = target
        model.targetText = "Name: ____"
        model.manualWidgetNames = ["client_a_checkbox"]
        model.startTargetScope(target)
        return model
    }

    private func assertNothingOfClientAIsLeft(
        _ model: FillModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.sourcePaths, [], "staged sources", file: file, line: line)
        XCTAssertEqual(model.sourceFailures, [], "extraction warnings", file: file, line: line)
        XCTAssertEqual(model.progress, 0, "extraction progress", file: file, line: line)
        XCTAssertTrue(model.blanks.isEmpty, "the plan's blanks", file: file, line: line)
        XCTAssertNil(model.selectedBlankID, file: file, line: line)
        XCTAssertNil(model.pickerRequestID, file: file, line: line)
        XCTAssertNil(model.targetURL, "the plan's target", file: file, line: line)
        XCTAssertNil(model.targetText, file: file, line: line)
        XCTAssertEqual(model.manualWidgetNames, [], file: file, line: line)
    }

    // MARK: - Every way to another profile

    func testOpeningAnotherProfileFromTheLibraryDropsWhatTheFirstStaged() async throws {
        let model = editorHoldingClientA()
        let notADirectory = workDir.appendingPathComponent("library")
        try Data("not a directory".utf8).write(to: notADirectory)
        FillModel.libraryRootForTesting = notADirectory

        await model.openForEdit(id: UUID())

        assertNothingOfClientAIsLeft(model)
    }

    func testFillFromAnotherProfileDropsWhatTheFirstStaged() async throws {
        let model = editorHoldingClientA()
        let notADirectory = workDir.appendingPathComponent("library")
        try Data("not a directory".utf8).write(to: notADirectory)
        FillModel.libraryRootForTesting = notADirectory

        await model.fillFrom(id: UUID())

        assertNothingOfClientAIsLeft(model)
    }

    func testLoadingAProfileFileDropsWhatTheFirstStaged() {
        let model = editorHoldingClientA()

        model.openExternalProfile(portfolio("Client B"))

        assertNothingOfClientAIsLeft(model)
        XCTAssertEqual(model.profile?.label, "Client B")
        XCTAssertNil(model.currentPortfolioID, "a file not in the library is saved as a new entry")
        XCTAssertEqual(model.stage, .profileReady)
    }

    func testGoingBackToTheLibraryDropsWhatTheProfileStaged() {
        let model = editorHoldingClientA()

        model.backToLibrary()

        assertNothingOfClientAIsLeft(model)
    }

    func testCreatingAPortfolioDropsWhatTheLastOneStaged() async {
        let model = editorHoldingClientA()

        await model.createPortfolio(kind: .company, label: "Client B", fromScratch: true,
                                    createdAtISO8601: "2026-11-11T00:00:00Z")

        assertNothingOfClientAIsLeft(model)
    }

    // MARK: - What stays

    func testAnExtractionThatLandsKeepsTheSourcesItRanOver() {
        let model = editorHoldingClientA()

        model.loadProfile(portfolio("Client A"))

        XCTAssertEqual(model.sourcePaths.count, 1, "Re-extract from Sources needs them")
    }
}
