import Foundation
import XCTest
@testable import LDACore

final class PackagingEntitlementsTests: XCTestCase {

    /// One packaging plist, parsed. Found relative to this test file so the
    /// check follows the repository rather than a hardcoded path.
    private func plist(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packaging")
            .appendingPathComponent(name)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil)
                as? [String: Any]
        )
    }

    func testInfoPlistDeclaresTheWorkspaceDocumentType() throws {
        // Double-click delivery depends entirely on this declaration. Without
        // it a .ldawork file is a generic document that opens in nothing, and
        // the format's "hand it to a colleague" promise stops at the Finder.
        let info = try plist("Info.plist")

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let workspace = try XCTUnwrap(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(WorkspaceArchive.uniformTypeIdentifier) == true
        })
        XCTAssertEqual(workspace["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(workspace["LSHandlerRank"] as? String, "Owner")

        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == WorkspaceArchive.uniformTypeIdentifier
        })
        // public.data and nothing more: the file is ciphertext, so no other app
        // should be told it can read into it.
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            [WorkspaceArchive.fileExtension],
            "the declared extension must match the one the app writes"
        )
    }

    func testInfoPlistDeclaresTheReportDocumentType() throws {
        // The encrypted report needs LDA to open it, so the app has to be the
        // thing a double-click reaches. Without this declaration the format's
        // "hand it to a colleague" promise stops at the Finder.
        let info = try plist("Info.plist")

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let report = try XCTUnwrap(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(ComplianceReportArchive.uniformTypeIdentifier) == true
        })
        XCTAssertEqual(report["LSHandlerRank"] as? String, "Owner")

        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == ComplianceReportArchive.uniformTypeIdentifier
        })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            [ComplianceReportArchive.fileExtension],
            "the declared extension must match the one the app writes"
        )
    }

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
