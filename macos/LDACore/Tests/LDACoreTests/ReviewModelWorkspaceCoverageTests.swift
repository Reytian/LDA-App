//
//  ReviewModelWorkspaceCoverageTests.swift
//  LDACoreTests
//
//  A workspace snapshot carries a document's review decisions so a colleague
//  can export without re-running detection. It must carry the AI coverage of
//  that result too: a failed or partial scan that required an Export for AI
//  confirmation before the workspace was saved has to require it after the
//  workspace is reopened, or saving and reopening becomes a way to lose the
//  warning.
//
//  The evidence this pins came from a probe against the real capture and
//  re-application: `ready=true, gate=didNotRun` became
//  `ready=true, gate=nil, warning=nil` with the same entities.
//
//  Deterministic detection only; no GGUF model is needed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ReviewModelWorkspaceCoverageTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelWorkspaceCoverageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    /// The Export for AI gate's verdict for one document, exactly as the shell
    /// computes it.
    private func gate(_ model: ReviewModel) -> ModelSetupPresentation.ExportGateReason? {
        ModelSetupPresentation.exportGateReason(documents: [
            (model.exportAvailability.isAvailable, model.aiActive, model.aiWarning, model.aiRanPartially)
        ])
    }

    private func writeSource() throws -> URL {
        let url = workDir.appendingPathComponent("synthetic.txt")
        try Data("Contact Jordan Lee at review-only@example.invalid.".utf8).write(to: url)
        return url
    }

    // MARK: - The round trip

    /// AI on, no model installed: the scan is ready but its Export for AI is
    /// gated. Save the workspace, reopen it on a fresh model, and the same
    /// review list must carry the same gate.
    func testReapplyingASnapshotKeepsTheExportGateOfTheResultItCarries() async throws {
        let source = try writeSource()
        let saved = ReviewModel(modelPath: nil)
        await saved.open(source)
        await saved.anonymize()

        // Premise: the finding's starting state.
        XCTAssertTrue(saved.exportAvailability.isAvailable)
        XCTAssertEqual(gate(saved), .didNotRun)
        XCTAssertFalse(saved.entities.isEmpty, "the pattern pass found the email")

        let snapshot = saved.workspaceSnapshot(documentID: UUID())

        let reopened = ReviewModel(modelPath: nil)
        await reopened.open(source)
        let applied = reopened.applyWorkspaceSnapshot(snapshot)

        XCTAssertEqual(applied.appliedCount, saved.entities.count)
        XCTAssertTrue(reopened.exportAvailability.isAvailable, "the restored review is still exportable")
        XCTAssertFalse(reopened.aiActive, "re-applying decisions is not an AI pass")
        XCTAssertNotNil(
            reopened.aiWarning,
            "the warning that gated the export before saving must gate it after reopening"
        )
        XCTAssertEqual(gate(reopened), .didNotRun)
    }

    // MARK: - What the snapshot records

    /// The record mirrors the gate: what the gate would have said before
    /// saving is what the snapshot says.
    func testASnapshotRecordsWhatTheAIPassDid() {
        let shapes: [(coverage: AIScanCoverage, record: WorkspaceAICoverage)] = [
            (AIScanCoverage(aiActive: true, aiWarning: nil, aiRanPartially: false), .complete),
            (AIScanCoverage(aiActive: false, aiWarning: nil, aiRanPartially: false), .notRequested),
            (AIScanCoverage(aiActive: false, aiWarning: "no model", aiRanPartially: false), .didNotRun),
            (AIScanCoverage(aiActive: false, aiWarning: "stopped short", aiRanPartially: true), .ranPartially)
        ]
        for shape in shapes {
            let model = ReviewModel(modelPath: nil)
            model.documentText = "Acme filed the notice."
            model.aiCoverage = shape.coverage
            XCTAssertEqual(
                model.workspaceSnapshot(documentID: UUID()).aiCoverage,
                shape.record,
                "\(shape.coverage) must be recorded as \(shape.record)"
            )
        }
    }

    // MARK: - What re-applying restores

    /// Each recorded shape comes back as itself: a clean pass stays clean, a
    /// pattern-only choice stays unwarned, and the two failure shapes keep
    /// the gate they had, the partial one with its flag.
    func testEachRecordedCoverageReappliesAsItself() {
        let text = "Acme filed the notice."
        let cases: [(record: WorkspaceAICoverage, aiActive: Bool, gate: ModelSetupPresentation.ExportGateReason?)] = [
            (.complete, true, nil),
            (.notRequested, false, nil),
            (.didNotRun, false, .didNotRun),
            (.ranPartially, false, .ranPartially)
        ]
        for testCase in cases {
            let model = ReviewModel(modelPath: nil)
            model.documentText = text
            model.applyWorkspaceSnapshot(WorkspaceReviewSnapshot(
                documentID: UUID(),
                textDigest: WorkspaceReviewSnapshot.digest(of: text),
                entities: [],
                aiCoverage: testCase.record
            ))
            XCTAssertEqual(model.status, .ready)
            XCTAssertEqual(model.aiActive, testCase.aiActive, "\(testCase.record)")
            XCTAssertEqual(gate(model), testCase.gate, "\(testCase.record)")
            XCTAssertEqual(model.aiRanPartially, testCase.record == .ranPartially, "\(testCase.record)")
            XCTAssertEqual(model.aiWarning == nil, testCase.gate == nil, "\(testCase.record)")
        }
    }

    /// A snapshot from before coverage was recorded: exactly the JSON the
    /// version 1 writer emitted. It must re-apply as a pass that did not run,
    /// because the alternative is to let an unknown pass read as a clean one.
    func testAnOlderSnapshotWithoutCoverageReappliesAsAPassThatDidNotRun() throws {
        let text = "Acme filed the notice."
        let json = "{\"documentID\":\"\(UUID().uuidString)\","
            + "\"textDigest\":\"\(WorkspaceReviewSnapshot.digest(of: text))\","
            + "\"entities\":[]}"
        let snapshot = try JSONDecoder().decode(WorkspaceReviewSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.aiCoverage, "fixture: the old shape carries no record")

        let model = ReviewModel(modelPath: nil)
        model.documentText = text
        model.applyWorkspaceSnapshot(snapshot)

        XCTAssertTrue(model.exportAvailability.isAvailable, "the decisions are still usable")
        XCTAssertFalse(model.aiActive)
        XCTAssertFalse(model.aiRanPartially)
        let warning = try XCTUnwrap(model.aiWarning, "unknown coverage must warn, never pass as clean")
        XCTAssertTrue(warning.contains("before LDA recorded"), "the warning says why it is guessing: \(warning)")
        XCTAssertEqual(gate(model), .didNotRun)
    }

    /// The warning is regenerated in the reader's language rather than copied
    /// from the saving Mac, so a colleague in another language reads it in
    /// theirs.
    func testTheRestoredWarningSpeaksTheReadersLanguage() {
        let english = AIScanCoverage.restored(from: .didNotRun, language: .english).aiWarning
        let french = AIScanCoverage.restored(from: .didNotRun, language: .french).aiWarning
        XCTAssertNotNil(english)
        XCTAssertNotEqual(english, french, "the French reader must not get the English sentence")
    }
}
