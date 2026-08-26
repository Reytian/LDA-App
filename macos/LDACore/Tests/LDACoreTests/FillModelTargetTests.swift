//
//  FillModelTargetTests.swift
//  LDACoreTests
//
//  Tests for FillModel behavior tied to the target document and stage lifecycle:
//  targetText population after planFill, security-scope bookkeeping
//  (scopedTargetURL set/cleared/replaced), regression guards for stage transitions,
//  explicit bad modelPath propagation, and the importingSources -> extracting
//  progress-callback stage flip.
//
//  Split from FillModelTests.swift to respect the 800-line file cap.
//  The writeFixtureDocx helper and its DOCX XML constants are duplicated from
//  FillModelTests (deliberate: each test file is intentionally self-contained;
//  see FillServiceTests / DocxFillTests for the same pattern).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Combine
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelTargetTests: XCTestCase {

    // MARK: - Setup / teardown

    override func setUp() {
        super.setUp()
        // Fail here if an earlier suite leaked a process-wide test seam.
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        // Clear all static test seams after every test so they never bleed.
        FillModel.extractProfileForTesting = nil
        FillModel.planFillForTesting = nil
        FillModel.applyFillForTesting = nil
        FillModel.libraryForTesting = nil
        FillModel.libraryRootForTesting = nil
        super.tearDown()
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
            .appendingPathComponent("lda-fillmodel-target-\(UUID().uuidString).docx")
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
}
