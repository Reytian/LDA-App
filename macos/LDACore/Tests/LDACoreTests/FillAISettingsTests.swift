import Foundation
import XCTest
@testable import LDAUI

@MainActor
final class FillAISettingsTests: XCTestCase {
    func testApplyingAISettingsUpdatesFillModelPath() throws {
        let suiteName = TestNamespace.suiteName("fill-ai-settings")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fill-model-" + UUID().uuidString + ".gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }
        try AISettings.selectCustomModel(at: modelURL, defaults: defaults)

        let fillModel = FillModel(modelPath: "/old/model.gguf")
        // bundledDefault was removed when tier resolution moved into
        // AISettings: Quick now comes from the app bundle and the other
        // tiers from the container, so a caller-supplied default has no
        // meaning. The behaviour under test, a custom model reaching the
        // fill window, is unchanged.
        AISettings.apply(to: fillModel, defaults: defaults)

        let appliedPath = try XCTUnwrap(fillModel.modelPath)
        XCTAssertEqual(
            URL(fileURLWithPath: appliedPath).resolvingSymlinksInPath(),
            modelURL.resolvingSymlinksInPath()
        )
    }
}
