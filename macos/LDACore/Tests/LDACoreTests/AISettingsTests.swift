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
        let resolvedPath = try XCTUnwrap(
            AISettings.resolveModelPath(bundledDefault: nil, defaults: defaults)
        )
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
        XCTAssertEqual(
            AISettings.resolveModelPath(bundledDefault: "/bundled/model.gguf", defaults: defaults),
            "/bundled/model.gguf"
        )
    }
}
