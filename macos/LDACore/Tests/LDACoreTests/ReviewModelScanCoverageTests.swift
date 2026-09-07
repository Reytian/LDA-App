//
//  ReviewModelScanCoverageTests.swift
//  LDACoreTests
//
//  The AI coverage of a scan result (did the AI pass run, did it finish, what
//  warning explains it) has to travel WITH that result. A cancelled retry
//  restores the previous result's status and entities; it must restore the
//  previous result's coverage too, or a failed or partial scan becomes
//  exportable without the warning that gated it before the retry.
//
//  The evidence this pins came from a probe against the real scan and cancel
//  orchestration: `ready=true, gate=didNotRun` turned into
//  `ready=true, gate=nil, warning=nil` after a cancelled retry.
//
//  Deterministic detection plus a test completer; no GGUF model is needed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ReviewModelScanCoverageTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelScanCoverageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ReviewModel.llmExtractorFactoryForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Blocks until the run's cancel token fires, then reports the stop,
    /// simulating a long generation the user interrupts.
    private final class BlockingUntilCancelled: TextCompleter, CancelAwareCompleter {
        var cancelToken: ExtractionCancelToken?
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            while cancelToken?.isCancelled != true {
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw LLMEngine.LLMError.cancelled
        }
    }

    /// An unterminated entities array: the extractor reports truncation, so
    /// the pass counts as having examined the document and stopped short.
    private struct AlwaysTruncating: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            #"{"entities":[{"value":"Jor"#
        }
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

    private func writeDummyModel() throws -> URL {
        let url = workDir.appendingPathComponent("dummy.gguf")
        try Data("synthetic".utf8).write(to: url)
        return url
    }

    /// Start a retry, wait until it is really detecting, stop it, and wait for
    /// the pass to unwind.
    private func cancelARetry(of model: ReviewModel) async throws {
        let run = Task { await model.anonymize() }
        var waited = 0
        while model.status != .detecting && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertEqual(model.status, .detecting, "the retry never started")
        model.cancelAnonymize()
        await run.value
    }

    // MARK: - Cancelling a retry

    /// AI on, no model installed: the first scan is ready but gated, because
    /// the AI pass did not run. A cancelled retry must leave it exactly there.
    func testCancellingARetryKeepsThePreviousDidNotRunWarning() async throws {
        let source = try writeSource()
        let model = ReviewModel(modelPath: nil)
        await model.open(source)
        await model.anonymize()

        // Premise: the finding's starting state.
        XCTAssertTrue(model.exportAvailability.isAvailable)
        XCTAssertEqual(gate(model), .didNotRun)
        let warningBefore = try XCTUnwrap(model.aiWarning)
        let entitiesBefore = model.entities

        // The user adds a model and retries, then stops the retry.
        model.modelPath = try writeDummyModel().path
        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: BlockingUntilCancelled(), cancelToken: cancel)
        }
        try await cancelARetry(of: model)

        XCTAssertEqual(model.status, .ready, "cancel restores the prior status")
        XCTAssertEqual(model.entities, entitiesBefore, "cancel keeps the prior entities")
        XCTAssertEqual(
            model.aiWarning, warningBefore,
            "the previous result's warning must survive a cancelled retry"
        )
        XCTAssertFalse(model.aiActive)
        XCTAssertEqual(
            gate(model), .didNotRun,
            "the previous result was gated before the retry and must be gated after it"
        )
    }

    /// The other coverage shape: a pass that examined the document and stopped
    /// short. All three coverage fields must come back, the partial flag
    /// included, because that flag chooses which confirmation the gate shows.
    func testCancellingARetryKeepsThePreviousPartialCoverage() async throws {
        let source = try writeSource()
        let model = ReviewModel(modelPath: try writeDummyModel().path)
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in
            LLMExtractor(completer: AlwaysTruncating())
        }
        await model.open(source)
        await model.anonymize()

        XCTAssertTrue(model.exportAvailability.isAvailable)
        XCTAssertEqual(gate(model), .ranPartially)
        XCTAssertTrue(model.aiRanPartially)
        let warningBefore = try XCTUnwrap(model.aiWarning)

        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: BlockingUntilCancelled(), cancelToken: cancel)
        }
        try await cancelARetry(of: model)

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.aiWarning, warningBefore)
        XCTAssertTrue(model.aiRanPartially, "the partial flag is part of the result")
        XCTAssertFalse(model.aiActive)
        XCTAssertEqual(gate(model), .ranPartially)
    }

    /// The counterpart that must NOT change: a retry that completes replaces
    /// the previous coverage with its own, so a clean AI pass lifts the gate.
    func testACompletedRetryReplacesThePreviousCoverage() async throws {
        let source = try writeSource()
        let model = ReviewModel(modelPath: nil)
        await model.open(source)
        await model.anonymize()
        XCTAssertEqual(gate(model), .didNotRun)

        struct CleanPass: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                #"{"entities":[{"value":"Jordan Lee","type":"PERSON"}],"redacted_text":""}"#
            }
        }
        model.modelPath = try writeDummyModel().path
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in
            LLMExtractor(completer: CleanPass())
        }
        await model.anonymize()

        XCTAssertEqual(model.status, .ready)
        XCTAssertTrue(model.aiActive)
        XCTAssertNil(model.aiWarning)
        XCTAssertNil(gate(model))
    }
}
