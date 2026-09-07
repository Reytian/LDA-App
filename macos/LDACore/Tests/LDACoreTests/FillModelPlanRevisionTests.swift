//
//  FillModelPlanRevisionTests.swift
//  LDACoreTests
//
//  R9: replanning the SAME target must retire the plan it replaces.
//
//  Planning freshness used to compare only the editor generation and the
//  target URL. Back to Profile changes neither, and re-selecting the same
//  target rewrites targetURL with the value it already had, so two planning
//  requests for one target could both read as current. Release the newer one
//  first and the older one second and the older wins:
//
//    SAME TARGET reordered plans: final=["Old Plan"]
//
//  What that costs is not cosmetic. The blanks a plan publishes are what
//  Apply writes into the form, and landing the older plan replaces the newer
//  suggestions AND every review decision the user made on them.
//
//  These tests drive the model alone through its planFill seam; the
//  library-backed halves live in FillModelLibraryTests, and the
//  occupant-change races in FillModelStaleCompletionTests.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelPlanRevisionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        FillModel.planFillForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let createdAt = "2026-09-07T00:00:00Z"
    private static let target = URL(fileURLWithPath: "/tmp/synthetic-target.docx")

    private func makePortfolio(companyName: String) -> ClientPortfolio {
        ClientPortfolio(
            label: "Synthetic Portfolio",
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

    private static let originalCompany = "Synthetic Alpha Holdings"
    private static let editedCompany = "Synthetic Alpha Holdings Limited"

    /// Poll the main actor until `condition` holds, so the test can act while
    /// planning is suspended in its detached work.
    private func waitUntil(
        _ failure: String,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        var waited = 0
        while !condition() && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(condition(), failure)
    }

    // MARK: - The review's ordering

    /// Plan the target, go Back to Profile, edit the profile, plan the SAME
    /// target again, then release the newer request first and the older one
    /// second. Only the newer plan may be on screen.
    func testAnOlderPlanForTheSameTargetCannotOverwriteTheNewerOne() async throws {
        // The two requests are told apart by the PROFILE each was matched
        // against, not by a shared counter: the seam runs off the main actor.
        let firstGate = DispatchSemaphore(value: 0)
        let original = Self.originalCompany
        FillModel.planFillForTesting = { _, profile in
            guard profile.fields.first?.value == original else {
                return FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: ["New Plan"])
            }
            firstGate.wait()
            return FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: ["Old Plan"])
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolio(companyName: Self.originalCompany))

        let older = Task { await model.planFill(target: Self.target) }
        try await waitUntil("the first plan never started") { model.stage == .planning }

        // Back to Profile, then a real edit, then the same target again. None
        // of the three changes the editor's occupant or the target URL.
        model.backToProfile()
        let fieldID = try XCTUnwrap(model.profile?.fields.first?.id)
        model.updateField(id: fieldID, value: Self.editedCompany)
        await model.planFill(target: Self.target)

        XCTAssertEqual(model.manualWidgetNames, ["New Plan"], "fixture: the newer plan landed")
        XCTAssertEqual(model.stage, .reviewing)

        firstGate.signal()
        await older.value

        XCTAssertEqual(
            model.manualWidgetNames, ["New Plan"],
            "the older plan replaced the newer suggestions and every decision on them"
        )
        XCTAssertEqual(model.stage, .reviewing)
    }

    /// Back to Profile abandons the plan outright. A request released after it
    /// must land nowhere at all, not even when no newer plan replaced it.
    func testAPlanAbandonedByBackToProfileLandsNowhere() async throws {
        let gate = DispatchSemaphore(value: 0)
        FillModel.planFillForTesting = { _, _ in
            gate.wait()
            return FillPlan(
                targetFormat: .docx,
                blanks: [],
                manualWidgetNames: ["Abandoned Plan"]
            )
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolio(companyName: Self.originalCompany))

        let planning = Task { await model.planFill(target: Self.target) }
        try await waitUntil("planning never started") { model.stage == .planning }

        model.backToProfile()
        gate.signal()
        await planning.value

        XCTAssertEqual(
            model.stage, .profileReady,
            "an abandoned plan put the editor back into review"
        )
        XCTAssertTrue(
            model.manualWidgetNames.isEmpty,
            "an abandoned plan published its blanks anyway"
        )
    }

    /// The failure half of the same rule: an abandoned plan that throws must
    /// not fail the profile the user went back to.
    func testAPlanAbandonedByBackToProfileDoesNotPublishItsFailure() async throws {
        struct SyntheticFailure: Error {}
        let gate = DispatchSemaphore(value: 0)
        FillModel.planFillForTesting = { _, _ in
            gate.wait()
            throw SyntheticFailure()
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolio(companyName: Self.originalCompany))

        let planning = Task { await model.planFill(target: Self.target) }
        try await waitUntil("planning never started") { model.stage == .planning }

        model.backToProfile()
        gate.signal()
        await planning.value

        XCTAssertEqual(
            model.stage, .profileReady,
            "an abandoned planning failure must not fail the profile builder"
        )
    }

    /// The ordinary case is untouched: one plan for one target still lands.
    func testASinglePlanStillLands() async throws {
        FillModel.planFillForTesting = { _, _ in
            FillPlan(targetFormat: .docx, blanks: [], manualWidgetNames: ["Only Plan"])
        }
        let model = FillModel(modelPath: "/fake/model.gguf")
        model.loadProfile(makePortfolio(companyName: Self.originalCompany))

        await model.planFill(target: Self.target)

        XCTAssertEqual(model.stage, .reviewing)
        XCTAssertEqual(model.manualWidgetNames, ["Only Plan"])
        XCTAssertEqual(model.targetURL, Self.target)
    }
}
