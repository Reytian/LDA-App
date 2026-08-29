import Foundation
import XCTest

final class PackagingEntitlementsTests: XCTestCase {
    func testSandboxEntitlementsAreExactlyWhatWeIntend() throws {
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
        // network.client is now PRESENT, deliberately. It was added so Manage
        // Models can download detection models the user asks for. This test
        // previously asserted its absence, which was correct until that
        // decision; the assertion is inverted rather than deleted so the
        // entitlement stays a conscious, tested choice.
        //
        // What must never change: nothing may connect INTO the app, and the
        // single-network-chokepoint invariant is enforced separately by
        // NetworkChokepointTests.
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true,
                       "model downloads need outbound access")
        XCTAssertNil(plist["com.apple.security.network.server"],
                     "nothing may connect into this app")
    }
}
