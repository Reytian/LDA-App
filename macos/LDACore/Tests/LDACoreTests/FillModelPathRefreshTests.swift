//
//  FillModelPathRefreshTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, T6. Fill's model path was set at launch and when the
//  custom model setting changed, never after a model was downloaded or
//  imported (neither changes that setting), so Fill kept running without the
//  model it now had until the app was relaunched.
//
//  FillModel now refreshes its configuration where each pass that uses the
//  model starts (extraction and planning), the way the review side
//  re-resolves its path at every scan; the app points the refresh at
//  AISettings.
//
//  Hermetic: the passes are replaced by the model's test seams. Every value
//  is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class FillModelPathRefreshTests: XCTestCase {

    override func setUp() {
        super.setUp()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        FillModel.extractProfileForTesting = nil
        FillModel.planFillForTesting = nil
        super.tearDown()
    }

    private func portfolio() -> ClientPortfolio {
        ClientPortfolio(
            label: "Client A", fields: [], sourceDocuments: [],
            createdAtISO8601: "2026-11-11T00:00:00Z", incomplete: false,
            kind: .company, modifiedAtISO8601: "2026-11-11T00:00:00Z"
        )
    }

    func testAnExtractionUsesTheModelDownloadedAfterLaunch() async {
        let model = FillModel(modelPath: nil)
        var refreshes = 0
        model.refreshConfiguration = { fill in
            refreshes += 1
            fill.modelPath = "/models/downloaded-after-launch.gguf"
        }
        let result = ExtractProfileResult(profile: portfolio(), failedSources: [])
        FillModel.extractProfileForTesting = { _, _, _, _, _ in result }

        await model.extractProfile(sources: [], label: "Client A", createdAtISO8601: "2026-11-11T00:00:00Z")

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(model.modelPath, "/models/downloaded-after-launch.gguf")
    }

    func testAPlanUsesTheModelDownloadedAfterLaunch() async {
        let model = FillModel(modelPath: nil)
        model.loadProfile(portfolio())
        var refreshes = 0
        model.refreshConfiguration = { fill in
            refreshes += 1
            fill.modelPath = "/models/downloaded-after-launch.gguf"
        }
        FillModel.planFillForTesting = { _, _ in FillPlan(targetFormat: .plainText, blanks: []) }

        await model.planFill(target: FileManager.default.temporaryDirectory.appendingPathComponent("form.txt"))

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(model.modelPath, "/models/downloaded-after-launch.gguf")
    }
}
