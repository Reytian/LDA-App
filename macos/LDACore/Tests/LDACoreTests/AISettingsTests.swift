import Foundation
import XCTest
@testable import LDAUI

@MainActor
final class AISettingsTests: XCTestCase {
    func testSelectingCustomModelPersistsSecurityScopedBookmark() throws {
        let suiteName = "AISettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-model-\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }

        try AISettings.selectCustomModel(at: modelURL, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: AISettings.customModelPathKey), modelURL.path)
        XCTAssertNotNil(defaults.data(forKey: AISettings.customModelBookmarkKey))
        let resolvedPath = try XCTUnwrap(AISettings.resolveModelPath(defaults: defaults))
        XCTAssertEqual(
            URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath(),
            modelURL.resolvingSymlinksInPath()
        )
    }

    func testClearingCustomModelRemovesPathAndBookmark() throws {
        let suiteName = "AISettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-model-\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }
        try AISettings.selectCustomModel(at: modelURL, defaults: defaults)

        AISettings.clearCustomModel(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: AISettings.customModelPathKey))
        XCTAssertNil(defaults.data(forKey: AISettings.customModelBookmarkKey))
        // Previously this asserted a caller-supplied bundledDefault was used.
        // Tier resolution now owns that: Quick comes from the app bundle and
        // the others from the container, so with the custom model cleared and
        // nothing installed in this test environment there is no model to fall
        // back to. The invariant under test, that clearing really releases the
        // custom model, is unchanged and asserted above.
        XCTAssertNil(AISettings.resolveModelPath(defaults: defaults))
    }
}
