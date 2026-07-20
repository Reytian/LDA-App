import Foundation
import XCTest

final class PackagingEntitlementsTests: XCTestCase {
    func testOfflineSandboxEntitlementsIncludePersistentUserSelectedFileAccess() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = packageRoot
            .appendingPathComponent("packaging")
            .appendingPathComponent("LDA.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(
            plist["com.apple.security.files.user-selected.read-write"] as? Bool,
            true
        )
        XCTAssertEqual(
            plist["com.apple.security.files.bookmarks.app-scope"] as? Bool,
            true
        )
        XCTAssertNil(plist["com.apple.security.network.client"])
        XCTAssertNil(plist["com.apple.security.network.server"])
    }
}
