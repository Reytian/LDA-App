//
//  OnboardingPageModelTests.swift
//  LDACoreTests
//
//  The wizard's page sequence and model-tier recommendation, tested as pure
//  functions on OnboardingPresentation rather than by grepping OnboardingView's
//  source: a rendered SwiftUI body is not inspectable, so these are the
//  functions the view calls to decide what page comes next and which rung it
//  pre-selects.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class OnboardingPageModelTests: XCTestCase {

    // MARK: - Page sequence

    func testFirstPageAndNextPage() {
        XCTAssertEqual(OnboardingPresentation.firstPage(mode: .firstRun), .language)
        XCTAssertEqual(OnboardingPresentation.firstPage(mode: .modelAskOnly), .model)

        XCTAssertEqual(
            OnboardingPresentation.nextPage(after: .language, mode: .firstRun, hasModel: false),
            .model
        )
        XCTAssertEqual(
            OnboardingPresentation.nextPage(after: .language, mode: .firstRun, hasModel: true),
            .steps
        )
        XCTAssertEqual(
            OnboardingPresentation.nextPage(after: .model, mode: .firstRun, hasModel: false),
            .steps
        )
        XCTAssertNil(
            OnboardingPresentation.nextPage(after: .model, mode: .modelAskOnly, hasModel: false)
        )
        XCTAssertNil(
            OnboardingPresentation.nextPage(after: .steps, mode: .firstRun, hasModel: false)
        )
        XCTAssertNil(
            OnboardingPresentation.nextPage(after: .steps, mode: .modelAskOnly, hasModel: false)
        )

        XCTAssertEqual(OnboardingPresentation.pageCount(mode: .firstRun, hasModel: false), 3)
        XCTAssertEqual(OnboardingPresentation.pageCount(mode: .firstRun, hasModel: true), 2)
        XCTAssertEqual(OnboardingPresentation.pageCount(mode: .modelAskOnly, hasModel: false), 1)
        XCTAssertEqual(OnboardingPresentation.pageCount(mode: .modelAskOnly, hasModel: true), 1)
    }

    func testPositionMatchesTheDocumentedSequences() {
        // language -> model -> steps, no model on this Mac.
        XCTAssertEqual(
            OnboardingPresentation.position(of: .language, mode: .firstRun, hasModel: false), 1
        )
        XCTAssertEqual(
            OnboardingPresentation.position(of: .model, mode: .firstRun, hasModel: false), 2
        )
        XCTAssertEqual(
            OnboardingPresentation.position(of: .steps, mode: .firstRun, hasModel: false), 3
        )
        // language -> steps, a model is already present.
        XCTAssertEqual(
            OnboardingPresentation.position(of: .language, mode: .firstRun, hasModel: true), 1
        )
        XCTAssertEqual(
            OnboardingPresentation.position(of: .steps, mode: .firstRun, hasModel: true), 2
        )
        // model -> dismiss, the return visit.
        XCTAssertEqual(
            OnboardingPresentation.position(of: .model, mode: .modelAskOnly, hasModel: false), 1
        )
    }

    func testStepChipHidesWhenThereIsOnlyOnePage() {
        XCTAssertNil(
            OnboardingPresentation.stepChip(position: 1, count: 1, language: .english)
        )
        XCTAssertEqual(
            OnboardingPresentation.stepChip(position: 2, count: 3, language: .english),
            "Step 2 of 3"
        )
    }

    // MARK: - The model-tier recommendation

    private func tier(id: String, level: String, peak: Double) -> ModelTier {
        ModelTier(
            id: id, level: level, displayName: id, fileName: "\(id).gguf",
            sizeBytes: 1_000, sha256: "", peakRSSGB: peak, secondsPerDocument: 10,
            architecture: "qwen35", blockCount: 32, embeddingLength: 2560,
            sourceURL: "https://example.invalid/\(id).gguf"
        )
    }

    /// The shipped ladder's measured peaks, so the boundary assertions below
    /// are the real boundary rather than a fixture's.
    private var ladder: ModelCatalog {
        ModelCatalog(tiers: [
            tier(id: "quick", level: "quick", peak: 3.6),
            tier(id: "balanced", level: "balanced", peak: 9.21),
            tier(id: "most-thorough", level: "mostThorough", peak: 13.83)
        ])
    }

    func testRecommendedLevel() {
        for installed in [8.0, 12.0] {
            XCTAssertNil(
                OnboardingPresentation.recommendedLevel(catalog: ladder, installedGB: installed),
                "\(installed) GB: the page is a statement, nothing is recommended"
            )
        }
        for installed in [16.0, 18.0, 19.5] {
            XCTAssertEqual(
                OnboardingPresentation.recommendedLevel(catalog: ladder, installedGB: installed),
                .quick,
                "\(installed) GB: Quick is the only rung that fits"
            )
        }
        for installed in [20.0, 24.0, 32.0] {
            XCTAssertEqual(
                OnboardingPresentation.recommendedLevel(catalog: ladder, installedGB: installed),
                .balanced,
                "\(installed) GB: Balanced fits with room to spare"
            )
        }
        for installed in [8.0, 16.0, 20.0, 24.0, 32.0, 64.0, 128.0] {
            XCTAssertNotEqual(
                OnboardingPresentation.recommendedLevel(catalog: ladder, installedGB: installed),
                .mostThorough,
                "\(installed) GB: Most thorough must never be pre-selected"
            )
        }
    }

    func testRecommendedLevelFallsBackToQuickWhenOnlyTheTightCaseIsSelectable() {
        // Balanced needs a budget of at least ~10.21 GB (its 9.21 GB peak plus
        // the 1 GB tight margin); at 19.5 GB the budget is under that, so only
        // Quick is selectable and it must still be the recommendation.
        XCTAssertEqual(
            OnboardingPresentation.recommendedLevel(catalog: ladder, installedGB: 19.5),
            .quick
        )
    }

    func testRecommendedLevelIsQuickWhenOnlyItsOwnTightCaseIsSelectable() {
        // A synthetic ladder with no Balanced tier at all, and a Quick peak
        // placed so its own margin over budget is under 1 GB (`.tight`) at
        // this installed size: budgetGB(12.93) is about 4.0 GB, so a 3.6 GB
        // peak clears it with only ~0.4 GB to spare.
        let quickOnly = ModelCatalog(tiers: [tier(id: "quick", level: "quick", peak: 3.6)])
        let availability = MemoryGate.availability(
            for: quickOnly.tier(for: .quick)!, installedGB: 12.93
        )
        XCTAssertEqual(availability, .tight, "the fixture must exercise the tight branch")
        XCTAssertEqual(
            OnboardingPresentation.recommendedLevel(catalog: quickOnly, installedGB: 12.93),
            .quick,
            "a tight-but-selectable Quick must still be recommended when it is all there is"
        )
    }

    // MARK: - The primary action selects what it installs

    func testTheWizardSelectsWhatItInstalls() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDAUI/OnboardingView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: "private var askActions") else {
            XCTFail("askActions is missing")
            return
        }
        let body = text[start.lowerBound...]
        XCTAssertTrue(
            body.contains("AISettings.setDetectionLevel("),
            "the primary action must select the rung it installs, not merely "
                + "download it, or a lawyer can download 13 GB and keep scanning "
                + "with Quick"
        )
    }
}
