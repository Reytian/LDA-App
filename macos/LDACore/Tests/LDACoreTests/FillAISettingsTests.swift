import Foundation
import XCTest
@testable import LDAUI

@MainActor
final class FillAISettingsTests: XCTestCase {
    func testApplyingAISettingsUpdatesFillModelPath() throws {
        let suiteName = "FillAISettingsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fill-model-" + UUID().uuidString + ".gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }
        try AISettings.selectCustomModel(at: modelURL, defaults: defaults)

        let fillModel = FillModel(modelPath: "/old/model.gguf")
        AISettings.apply(to: fillModel, bundledDefault: nil, defaults: defaults)

        let appliedPath = try XCTUnwrap(fillModel.modelPath)
        XCTAssertEqual(
            URL(fileURLWithPath: appliedPath).resolvingSymlinksInPath(),
            modelURL.resolvingSymlinksInPath()
        )
    }
}
