//
//  FillModelStaleCompletionTests.swift
//  LDACoreTests
//
//  FillModel's asynchronous intents (extractProfile, planFill, applyFill)
//  suspend for seconds to minutes, and the editor is free to move on while
//  they run: Back to Library, open another portfolio, start another
//  extraction, open another target. A completion that lands after the editor
//  moved on must land nowhere, because the failure it would cause is
//  concrete: extraction A finishes into portfolio B's editor under B's id,
//  and the next Save writes A's data over B.
//
//  The evidence this pins came from a probe against the real model:
//  `profile=Synthetic Portfolio A, saveStillTargetsB=true, profileDirty=true,
//  canSaveToLibrary=true` after A completed with B open.
//
//  The library-backed halves (a real PortfolioLibrary over a temp root) live
//  in FillModelLibraryTests; these tests drive the model alone through its
//  seams. The "open B" step here is the exact state transition openForEdit
//  makes after its library read.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelStaleCompletionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Fail here if an earlier suite leaked a process-wide test seam.
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        FillModel.extractProfileForTesting = nil
        FillModel.planFillForTesting = nil
        FillModel.applyFillForTesting = nil
        FillModel.libraryForTesting = nil
        FillModel.libraryRootForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let createdAt = "2026-09-06T00:00:00Z"
    private static let source = URL(fileURLWithPath: "/tmp/synthetic-source.txt")
    private static let target = URL(fileURLWithPath: "/tmp/synthetic-target.docx")

    /// A portfolio with one company-name field, so a stale landing would have
    /// something visible to overwrite.
    private func makePortfolio(label: String, companyName: String) -> ClientPortfolio {
        ClientPortfolio(
            label: label,
            fields: [
                ProfileField(
                    id: UUID(),
                    key: .companyName,
                    value: companyName,
                    sourceDocument: "synthetic.txt",
                    sourceSnippet: companyName,
                    snippetVerified: true,
                    confidence: 1.0,
                    userEdited: false
                )
            ],
            sourceDocuments: ["synthetic.txt"],
            createdAtISO8601: Self.createdAt,
            incomplete: false
        )
    }

    private func makePortfolioA() -> ClientPortfolio {
        makePortfolio(label: "Synthetic Portfolio A", companyName: "Synthetic Alpha Holdings")
    }

    private func makePortfolioB() -> ClientPortfolio {
        makePortfolio(label: "Synthetic Portfolio B", companyName: "Synthetic Beta Trading")
    }

    /// Blocks the extraction seam until the test releases it, so the test can
    /// change what the editor holds while the extraction is in flight.
    private func installBlockedExtraction(returning profile: ClientPortfolio) -> DispatchSemaphore {
        let blocker = DispatchSemaphore(value: 0)
        FillModel.extractProfileForTesting = { _, _, _, _, _ in
            blocker.wait()
            return ExtractProfileResult(profile: profile, failedSources: [])
        }
        return blocker
    }

    /// Poll the main actor until `condition` holds, so the test can act while
    /// an intent is suspended in its detached work.
    private func waitUntil(_ failure: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        var waited = 0
        while !condition() && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(condition(), failure)
    }

    /// Start an extraction and wait until the model has actually entered it.
    private func startExtraction(on model: FillModel, label: String) async throws -> Task<Void, Never> {
        let extracting = Task {
            await model.extractProfile(sources: [Self.source], label: label, createdAtISO8601: Self.createdAt)
        }
        try await waitUntil("the extraction never started") { model.stage == .importingSources }
        return extracting
    }

    /// Back to the library, then open another portfolio: the exact state
    /// transition openForEdit makes after its library read.
    private func openFromLibrary(_ portfolio: ClientPortfolio, id: UUID, in model: FillModel) {
        model.backToLibrary()
        model.currentPortfolioID = id
        model.loadProfile(portfolio)
    }

    // MARK: - Extraction

    /// The review probe: extraction A is running, the user goes back to the
    /// library and opens portfolio B, then A finishes. A's profile must not
    /// land in B's editor under B's id, where the next Save would write A's
    /// data over B.
    func testAStaleExtractionDoesNotReplaceThePortfolioOpenedAfterIt() async throws {
        let portfolioA = makePortfolioA()
        let portfolioB = makePortfolioB()
        let portfolioBID = UUID()
        let blocker = installBlockedExtraction(returning: portfolioA)
        let model = FillModel(modelPath: "/fake/model.gguf")
        let extracting = try await startExtraction(on: model, label: portfolioA.label)

        openFromLibrary(portfolioB, id: portfolioBID, in: model)

        blocker.signal()
        await extracting.value

        XCTAssertEqual(model.profile?.label, portfolioB.label, "A's profile landed in B's editor")
        XCTAssertEqual(model.currentPortfolioID, portfolioBID, "B's identity must be untouched")
        XCTAssertFalse(model.profileDirty, "a stale extraction must not mark B's clean profile as unsaved work")
        XCTAssertEqual(model.stage, .profileReady)
    }

    /// The failure branch of the same race: a stale extraction that fails
    /// must not put B's editor into the failed state either.
    func testAStaleExtractionFailureDoesNotDisturbThePortfolioOpenedAfterIt() async throws {
        struct SyntheticFailure: Error {}
        let blocker = DispatchSemaphore(value: 0)
        FillModel.extractProfileForTesting = { _, _, _, _, _ in
            blocker.wait()
            throw SyntheticFailure()
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        let extracting = try await startExtraction(on: model, label: "Synthetic Portfolio A")

        openFromLibrary(makePortfolioB(), id: UUID(), in: model)

        blocker.signal()
        await extracting.value

        XCTAssertEqual(model.stage, .profileReady, "a stale failure must not fail the editor that replaced it")
        XCTAssertEqual(model.profile?.label, "Synthetic Portfolio B")
    }

    /// A second extraction started for the same editor supersedes the first:
    /// only the later result may land.
    func testALaterExtractionSupersedesAnEarlierOneStillInFlight() async throws {
        let first = makePortfolio(label: "Synthetic Portfolio", companyName: "First Result")
        let second = makePortfolio(label: "Synthetic Portfolio", companyName: "Second Result")
        let blocker = installBlockedExtraction(returning: first)
        let model = FillModel(modelPath: "/fake/model.gguf")
        let earlier = try await startExtraction(on: model, label: "Synthetic Portfolio")

        FillModel.extractProfileForTesting = { _, _, _, _, _ in
            ExtractProfileResult(profile: second, failedSources: [])
        }
        await model.extractProfile(sources: [Self.source], label: "Synthetic Portfolio", createdAtISO8601: Self.createdAt)
        XCTAssertEqual(model.profile?.fields.first?.value, "Second Result")

        blocker.signal()
        await earlier.value

        XCTAssertEqual(
            model.profile?.fields.first?.value, "Second Result",
            "the earlier extraction must not overwrite the later one"
        )
        XCTAssertEqual(model.stage, .profileReady)
    }

    // MARK: - Planning

    /// The same race through planFill: A's blanks were matched against A's
    /// profile. If B is opened while planning runs, the plan must not put
    /// B's editor into review, where Apply would fill a form from A's values
    /// under B's name.
    func testAStalePlanDoesNotPutThePortfolioOpenedAfterItIntoReview() async throws {
        let blocker = DispatchSemaphore(value: 0)
        FillModel.planFillForTesting = { _, _ in
            blocker.wait()
            return FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: ["Signature"])
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolioA())
        let planning = Task { await model.planFill(target: Self.target) }
        try await waitUntil("planning never started") { model.stage == .planning }

        let portfolioBID = UUID()
        openFromLibrary(makePortfolioB(), id: portfolioBID, in: model)

        blocker.signal()
        await planning.value

        XCTAssertEqual(model.stage, .profileReady, "A's plan put B's editor into review")
        XCTAssertTrue(model.manualWidgetNames.isEmpty, "A's plan landed in B's editor")
        XCTAssertEqual(model.profile?.label, "Synthetic Portfolio B")
        XCTAssertEqual(model.currentPortfolioID, portfolioBID)
    }

    /// A stale plan that fails must not fail the editor that replaced it.
    func testAStalePlanFailureDoesNotDisturbThePortfolioOpenedAfterIt() async throws {
        struct SyntheticFailure: Error {}
        let blocker = DispatchSemaphore(value: 0)
        FillModel.planFillForTesting = { _, _ in
            blocker.wait()
            throw SyntheticFailure()
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolioA())
        let planning = Task { await model.planFill(target: Self.target) }
        try await waitUntil("planning never started") { model.stage == .planning }

        openFromLibrary(makePortfolioB(), id: UUID(), in: model)

        blocker.signal()
        await planning.value

        XCTAssertEqual(model.stage, .profileReady, "a stale planning failure must not fail B's editor")
        XCTAssertEqual(model.profile?.label, "Synthetic Portfolio B")
    }

    /// Opening a second target while the first is still being planned: only
    /// the later plan may land, because applyFill fills whatever targetURL
    /// names with whatever blanks are published.
    func testALaterTargetSupersedesAPlanStillInFlight() async throws {
        let secondTarget = URL(fileURLWithPath: "/tmp/synthetic-second.pdf")
        let blocker = DispatchSemaphore(value: 0)
        FillModel.planFillForTesting = { target, _ in
            guard target == secondTarget else {
                blocker.wait()
                return FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: ["First"])
            }
            return FillPlan(targetFormat: .pdf, blanks: [], manualWidgetNames: ["Second"])
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolioA())
        let first = Task { await model.planFill(target: Self.target) }
        try await waitUntil("planning never started") { model.stage == .planning }

        await model.planFill(target: secondTarget)
        XCTAssertEqual(model.stage, .reviewing)
        XCTAssertEqual(model.manualWidgetNames, ["Second"])

        blocker.signal()
        await first.value

        XCTAssertEqual(model.manualWidgetNames, ["Second"], "the earlier plan must not overwrite the later one")
        XCTAssertEqual(model.targetURL, secondTarget)
        XCTAssertEqual(model.stage, .reviewing)
    }

    // MARK: - Applying

    /// The same race through applyFill: the filled document belongs to A's
    /// fill session. If B is opened while the apply runs, its report must not
    /// be shown as B's; the file is on disk either way.
    func testAStaleApplyDoesNotMarkThePortfolioOpenedAfterItDone() async throws {
        FillModel.planFillForTesting = { _, _ in
            FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: ["Signature"])
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolioA())
        await model.planFill(target: Self.target)
        XCTAssertEqual(model.stage, .reviewing, "fixture: A is in review")

        let blocker = DispatchSemaphore(value: 0)
        let report = FillReport(
            outputURL: URL(fileURLWithPath: "/tmp/synthetic-out/filled.docx"),
            filledCount: 0,
            skipped: []
        )
        FillModel.applyFillForTesting = { _, _, _ in
            blocker.wait()
            return report
        }
        let applying = Task { await model.applyFill(outputDir: URL(fileURLWithPath: "/tmp/synthetic-out")) }
        try await waitUntil("applying never started") { model.stage == .applying }

        openFromLibrary(makePortfolioB(), id: UUID(), in: model)

        blocker.signal()
        await applying.value

        XCTAssertEqual(model.stage, .profileReady, "A's report landed on B's editor")
        XCTAssertEqual(model.profile?.label, "Synthetic Portfolio B")
    }
}
